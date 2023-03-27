# The toolchain container encodes environment
# downloads essential dependencies.
FROM ubuntu:18.04 as toolchain
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update -qq && apt-get -qq install unzip rsync

# Install toolchains: Android NDK & Java JDK.
WORKDIR /opt/ndk
ADD downloads/ndk/* .
RUN unzip -q android-ndk-*-linux.zip && rm android-ndk-*.zip && mv android-ndk-* android-ndk
ENV NDK /opt/ndk/android-ndk
WORKDIR /opt/jdk
ADD downloads/jdk/* .
RUN mv jdk* jdk_home
ENV JAVA_HOME /opt/jdk/jdk_home
ENV PATH "/opt/jdk/jdk_home/bin:${PATH}"

# Store output here; the directory structure corresponds to our Android app template.
ENV APPROOT /opt/python-build/approot
# Do our Python build work here
ENV BUILD_HOME "/opt/python-build"
ENV PYTHON_INSTALL_DIR="$BUILD_HOME/built/python"
WORKDIR /opt/python-build

# Configure build variables
ENV HOST_TAG="linux-x86_64"
ARG TARGET_ABI_SHORTNAME
ENV TARGET_ABI_SHORTNAME $TARGET_ABI_SHORTNAME
ARG ANDROID_API_LEVEL
ENV ANDROID_API_LEVEL $ANDROID_API_LEVEL
ENV JNI_LIBS $APPROOT/app/libs/${TARGET_ABI_SHORTNAME}
ARG TOOLCHAIN_TRIPLE
ENV TOOLCHAIN_TRIPLE $TOOLCHAIN_TRIPLE
ENV TOOLCHAIN=$NDK/toolchains/llvm/prebuilt/$HOST_TAG
ARG COMPILER_TRIPLE
ENV COMPILER_TRIPLE=$COMPILER_TRIPLE
ENV AR=$TOOLCHAIN/bin/llvm-ar \
    AS=$TOOLCHAIN/bin/llvm-as \
    CC=$TOOLCHAIN/bin/${COMPILER_TRIPLE}-clang \
    CXX=$TOOLCHAIN/bin/${COMPILER_TRIPLE}-clang++ \
    LD=$TOOLCHAIN/bin/ld \
    RANLIB=$TOOLCHAIN/bin/llvm-ranlib \
    STRIP=$TOOLCHAIN/bin/llvm-strip \
    READELF=$TOOLCHAIN/bin/llvm-readelf \
    CFLAGS="-fPIC -Wall -Os" \
    LDFLAGS="-Wl,-S"

# Set up a directory for logs.
ENV LOGS_DIR=${BUILD_HOME}/logs/${TARGET_ABI_SHORTNAME}
RUN mkdir -p ${LOGS_DIR}

# We build sqlite from official sources. It requires tcl8.6-dev and build-essential
# because the compile process build and executes some commands on the host as part of the build process.
# We hard-code avoid_version=yes into libtool so that libsqlite3.so is the SONAME.
FROM toolchain as build_sqlite
RUN apt-get update -qq && apt-get -qq install make autoconf autotools-dev tcl8.6-dev build-essential
ADD downloads/sqlite3/* .
RUN unzip -q version-*.zip && mv sqlite-* sqlite3-src
RUN cd sqlite3-src && autoreconf
RUN cd sqlite3-src && ./configure --host "$TOOLCHAIN_TRIPLE" --build "$COMPILER_TRIPLE" --prefix="$BUILD_HOME/built/sqlite" | tee -a $LOGS_DIR/sqlite3.configure.log
RUN cd sqlite3-src && sed -i -E 's,avoid_version=no,avoid_version=yes,' ltmain.sh libtool
RUN cd sqlite3-src && make install | tee -a $LOGS_DIR/sqlite3.install.log

# Install bzip2 & lzma libraries, for stdlib's _bzip2 and _lzma modules.
FROM toolchain as build_xz
RUN apt-get update -qq && apt-get -qq install make
ADD downloads/xz/* .
RUN mv xz-* xz-src
ENV LIBXZ_INSTALL_DIR="$BUILD_HOME/built/xz"
RUN mkdir -p "$LIBXZ_INSTALL_DIR"
RUN cd xz-src && ./configure --host "$TOOLCHAIN_TRIPLE" --build "$COMPILER_TRIPLE" --prefix="$LIBXZ_INSTALL_DIR" | tee -a $LOGS_DIR/xz.configure.log
RUN cd xz-src && make install | tee -a $LOGS_DIR/xz.install.log

FROM toolchain as build_bz2
RUN apt-get update -qq && apt-get -qq install make
ENV LIBBZ2_INSTALL_DIR="$BUILD_HOME/built/libbz2"
ADD downloads/bzip2/* .
RUN mv bzip2-* bzip2-src
RUN mkdir -p "$LIBBZ2_INSTALL_DIR" && \
    cd bzip2-src && \
    sed -i -e 's,[.]1[.]0.8,,' -e 's,[.]1[.]0,,' -e 's,ln -s,#ln -s,' -e 's,rm -f libbz2.so,#rm -f libbz2.so,' -e 's,^CC=,#CC=,' Makefile-libbz2_so
RUN cd bzip2-src && make -f Makefile-libbz2_so | tee -a $LOGS_DIR/bz2.log
RUN mkdir -p "${LIBBZ2_INSTALL_DIR}/lib"
RUN cp bzip2-src/libbz2.so "${LIBBZ2_INSTALL_DIR}/lib"
RUN mkdir -p "${LIBBZ2_INSTALL_DIR}/include"
RUN cp bzip2-src/bzlib.h "${LIBBZ2_INSTALL_DIR}/include"

# libffi is required by ctypes
FROM toolchain as build_libffi
RUN apt-get update -qq && apt-get -qq install file make
ADD downloads/libffi/* .
RUN mv libffi-* libffi-src
ENV LIBFFI_INSTALL_DIR="$BUILD_HOME/built/libffi"
RUN mkdir -p "$LIBFFI_INSTALL_DIR"
RUN cd libffi-src && ./configure --host "$TOOLCHAIN_TRIPLE" --build "$COMPILER_TRIPLE" --prefix="$LIBFFI_INSTALL_DIR" | tee -a $LOGS_DIR/libffi.configure.log
RUN cd libffi-src && make install | tee -a $LOGS_DIR/libffi.install.log

FROM toolchain as build_openssl
# OpenSSL requires libfindlibs-libs-perl. make is nice, too.
RUN apt-get update -qq && apt-get -qq install libfindbin-libs-perl make
ADD downloads/openssl/* .
RUN mv openssl-* openssl-src
ARG OPENSSL_BUILD_TARGET
RUN cd openssl-src && ANDROID_NDK_HOME="$NDK" ./Configure ${OPENSSL_BUILD_TARGET} -D__ANDROID_API__="$ANDROID_API_LEVEL" --prefix="$BUILD_HOME/built/openssl" --openssldir="$BUILD_HOME/built/openssl" | tee -a $LOGS_DIR/openssl.configure.log
RUN cd openssl-src && make SHLIB_EXT='${SHLIB_VERSION_NUMBER}.so' | tee -a $LOGS_DIR/openssl.build.log
RUN cd openssl-src && make install SHLIB_EXT='${SHLIB_VERSION_NUMBER}.so' | tee -a $LOGS_DIR/openssl.install.log

# This build container builds Python, rubicon-java, and any dependencies. Each Python version
# requires itself to be installed globally during a cross-compile.
FROM toolchain as build_python
RUN apt-get update -qq && apt-get -qq install software-properties-common dirmngr apt-transport-https lsb-release ca-certificates
RUN apt-add-repository ppa:deadsnakes/ppa
RUN apt-get update -qq && apt-get -qq install python3.7 python3.8 python3.9 python3.10 python3.11 pkg-config zip quilt

# Get libs & vars from the build stages
COPY --from=build_openssl /opt/python-build/built/openssl /opt/python-build/built/openssl
COPY --from=build_bz2 /opt/python-build/built/libbz2 /opt/python-build/built/libbz2
COPY --from=build_xz /opt/python-build/built/xz /opt/python-build/built/xz
COPY --from=build_libffi /opt/python-build/built/libffi /opt/python-build/built/libffi
COPY --from=build_sqlite /opt/python-build/built/sqlite /opt/python-build/built/sqlite

# Copy logs from the build stages
COPY --from=build_openssl $LOGS_DIR/* $LOGS_DIR
COPY --from=build_bz2 $LOGS_DIR/* $LOGS_DIR
COPY --from=build_xz $LOGS_DIR/* $LOGS_DIR
COPY --from=build_libffi $LOGS_DIR/* $LOGS_DIR
COPY --from=build_sqlite $LOGS_DIR/* $LOGS_DIR

ENV OPENSSL_INSTALL_DIR=/opt/python-build/built/openssl
ENV LIBBZ2_INSTALL_DIR="$BUILD_HOME/built/libbz2"
ENV LIBXZ_INSTALL_DIR="$BUILD_HOME/built/xz"
RUN mkdir -p "$JNI_LIBS" && cp -a "$OPENSSL_INSTALL_DIR"/lib/*.so "$LIBBZ2_INSTALL_DIR"/lib/*.so /opt/python-build/built/libffi/lib/*.so /opt/python-build/built/xz/lib/*.so /opt/python-build/built/sqlite/lib/*.so "$JNI_LIBS"
ENV PKG_CONFIG_PATH="/opt/python-build/built/libffi/lib/pkgconfig:/opt/python-build/built/openssl/lib/pkgconfig:/opt/python-build/built/sqlite/lib/pkgconfig:/opt/python-build/built/xz/lib/pkgconfig"

# Download & patch Python. We assume that there is only one Python-${VERSION}.*.tar.xz file.
ARG PYTHON_VERSION
ADD downloads/python-${PYTHON_VERSION}/* .
RUN mv Python-* python-src
# Modify ./configure so that, even though this is Linux, it does not append .1.0 to the .so file.
RUN sed -i -e 's,INSTSONAME="$LDLIBRARY".$SOVERSION,,' python-src/configure
# Modify Makefile.* so that libpython3.*.so gets a SONAME. This is required because
# upstream's build system only sets the SONAME for libpython3.*.so.1.0 (which it sets
# to libpython3.*.so.1.0, which doesn't work for us on Android because we need the
# .so to end in .so). In the process, avoid calling `ln` to link the file to itself,
# which will fail.
RUN sed -i -e s,'test $(INSTSONAME) != $(LDLIBRARY)',true, -e s,'$(LN) -f $(INSTSONAME) $@;,,' python-src/Makefile.*
ARG PYTHON_SOVERSION
# Apply a C extensions linker hack; already fixed in Python 3.8+; see https://github.com/python/cpython/commit/254b309c801f82509597e3d7d4be56885ef94c11
RUN sed -i -e s,'libraries or \[\],\["pythonPYTHON_SOVERSION"] + libraries if libraries else \["pythonPYTHON_SOVERSION"\],' -e  "s,pythonPYTHON_SOVERSION,python${PYTHON_SOVERSION},g" python-src/Lib/distutils/extension.py
# Apply a hack to get the NDK library paths into the Python build.
# TODO(someday): Discuss with e.g. Kivy and see how to remove this.
RUN sed -i -e "s# dirs = \[\]# dirs = \[os.environ.get('SYSROOT_INCLUDE'), os.environ.get('SYSROOT_LIB') \]#" python-src/setup.py
# Apply a hack to get the sqlite include path into setup.py. TODO(someday): Discuss with upstream Python if we can use pkg-config for sqlite.
RUN sed -i -E 's,sqlite_inc_paths = [[][]],sqlite_inc_paths = ["/opt/python-build/built/sqlite/include"],' python-src/setup.py
# Apply a hack to make platform.py stop looking for a libc version.
RUN sed -i -e "s#Linux#DisabledLinuxCheck#" python-src/Lib/platform.py

# Apply our patches to Python. See patches/3.*/* for details.
ADD patches/${PYTHON_VERSION} python-src/patches
RUN cd python-src && if [ "$(wc -l < patches/series)" != "0" ] ; then quilt push -a; else echo "No patches." ; fi

# Add a Setup.local configuration
RUN cp python-src/patches/Setup.local python-src/Modules

# Build Python, pre-configuring some values so it doesn't check if those exist.
ENV SYSROOT_LIB=${TOOLCHAIN}/sysroot/usr/lib/${TOOLCHAIN_TRIPLE}/${ANDROID_API_LEVEL}/ \
    SYSROOT_INCLUDE=${TOOLCHAIN}/sysroot/usr/include/
# Add any version-specific configuration flags
ARG PYTHON_EXTRA_CONFIGURE_FLAGS
ENV PYTHON_EXTRA_CONFIGURE_FLAGS $PYTHON_EXTRA_CONFIGURE_FLAGS
# Call ./configure with enough parameters to work.
RUN cd python-src && LDFLAGS="${LDFLAGS} $(pkg-config --libs-only-L libffi) $(pkg-config --libs-only-L liblzma) -L${LIBBZ2_INSTALL_DIR}/lib -L$OPENSSL_INSTALL_DIR/lib" \
    CFLAGS="${CFLAGS} -I${LIBBZ2_INSTALL_DIR}/include $(pkg-config --cflags-only-I libffi) $(pkg-config --cflags-only-I liblzma)" \
    ./configure \
    --host "$TOOLCHAIN_TRIPLE" \
    --build "$COMPILER_TRIPLE" \
    --prefix="$PYTHON_INSTALL_DIR" \
    --enable-shared \
    --enable-ipv6 \
    --with-openssl=$OPENSSL_INSTALL_DIR \
    --with-ensurepip=install \
    ac_cv_file__dev_ptmx=yes \
    ac_cv_file__dev_ptc=no \
    ac_cv_little_endian_double=yes \
    $PYTHON_EXTRA_CONFIGURE_FLAGS \
    ac_cv_func_setuid=no \
    ac_cv_func_seteuid=no \
    ac_cv_func_setegid=no \
    ac_cv_func_getresuid=no \
    ac_cv_func_setresgid=no \
    ac_cv_func_setgid=no \
    ac_cv_func_sethostname=no \
    ac_cv_func_setresuid=no \
    ac_cv_func_setregid=no \
    ac_cv_func_setreuid=no \
    ac_cv_func_getresgid=no \
    ac_cv_func_setregid=no \
    ac_cv_func_clock_settime=no \
    ac_cv_func_sendfile=no \
    ac_cv_header_spawn_h=no \
    ac_cv_func_posix_spawn=no \
    ac_cv_func_setlocale=no \
    ac_cv_working_tzset=no \
    ac_cv_member_struct_tm_tm_zone=no \
    ac_cv_func_sched_setscheduler=no | tee -a $LOGS_DIR/python.configure.log
# Override ./configure results to futher force Python not to use some libc calls that trigger blocked syscalls.
# TODO(someday): See if HAVE_INITGROUPS has another way to disable it.
RUN cd python-src && sed -i -E 's,#define (HAVE_CHROOT|HAVE_SETGROUPS|HAVE_INITGROUPS) 1,,' pyconfig.h
# Adjust timemodule.c to perform data validation for mktime(). The libc call is supposed to do its own
# validation, but on one Android 8.1 device, it doesn't. We leverage the existing AIX-related check in timemodule.c.
RUN cd python-src && sed -i -E 's,#ifdef _AIX,#if defined(_AIX) || defined(__ANDROID__),' Modules/timemodule.c
# Override posixmodule.c assumption that fork & exec exist & work.
RUN cd python-src && sed -i -E 's,#define.*(HAVE_EXECV|HAVE_FORK).*1,,' Modules/posixmodule.c
# Copy libbz2 into the SYSROOT_LIB. This is the IMHO the easiest way for setup.py to find it.
RUN cp "${LIBBZ2_INSTALL_DIR}/lib/libbz2.so" $SYSROOT_LIB
# Compile Python. We can still remove some tests from the test suite before `make install`.
RUN cd python-src && make | tee -a $LOGS_DIR/python.build.log

# Modify stdlib & test suite before `make install`.

# Apply a hack to ctypes so that it loads libpython.so, even though this isn't Windows.
RUN sed -i -e 's,pythonapi = PyDLL(None),pythonapi = PyDLL("libpythonPYTHON_SOVERSION.so"),'  -e "s,libpythonPYTHON_SOVERSION,libpython${PYTHON_SOVERSION},g" python-src/Lib/ctypes/__init__.py
# Hack the test suite so that when it tries to remove files, if it can't remove them, the error passes silently.
# To see if ths is still an issue, run `test_bdb`.
RUN sed -i -e "s#NotADirectoryError#NotADirectoryError, OSError#" python-src/Lib/test/support/__init__.py
# Ignore some tests
ADD patches/all/ignore_some_tests.py .
RUN python3.7 ignore_some_tests.py $(find python-src/Lib/test -iname '*.py') $(find python-src/Lib/distutils/tests -iname '*.py') $(find python-src/Lib/unittest/test/ -iname '*.py') $(find python-src/Lib/lib2to3/tests -iname '*.py')
# Skip test_multiprocessing in test_venv.py. Not sure why this fails yet.
RUN cd python-src && sed -i -e 's,def test_multiprocessing,def skip_test_multiprocessing,' Lib/test/test_venv.py
# Skip test_faulthandler & test_signal & test_threadsignals. Signal delivery on Android is not super reliable.
RUN cd python-src && rm Lib/test/test_faulthandler.py Lib/test/test_signal.py Lib/test/test_threadsignals.py
# In test_cmd_line.py:
# - test_empty_PYTHONPATH_issue16309() fails. I think it is because it assumes PYTHONHOME is set;
#   if we can fix our dependency on that variable for Python subprocesses, we'd be better off.
# - test_stdout_flush_at_shutdown() fails. The situation is that the test assumes you can't
#   close() a FD (stdout) that's already been closed; however, seemingly, on Android, you can.
RUN cd python-src && sed -i -e 's,def test_empty_PYTHONPATH_issue16309,def skip_test_empty_PYTHONPATH_issue16309,' Lib/test/test_cmd_line.py
RUN cd python-src && sed -i -e 's,def test_stdout_flush_at_shutdown,def skip_test_stdout_flush_at_shutdown,' Lib/test/test_cmd_line.py
# TODO(someday): restore asyncio tests & fix them
RUN cd python-src && rm -rf Lib/test/test_asyncio
# TODO(someday): restore subprocess tests & fix them
RUN cd python-src && rm Lib/test/test_subprocess.py
# TODO(someday): Restore test_httpservers tests. They depend on os.setuid() existing, and they have
# little meaning in Android.
RUN cd python-src && rm Lib/test/test_httpservers.py
# TODO(someday): restore xmlrpc tests & fix them; right now they hang forever.
RUN cd python-src && rm Lib/test/test_xmlrpc.py
# TODO(someday): restore wsgiref tests & fix them; right now they hang forever.
RUN cd python-src && rm Lib/test/test_wsgiref.py

# Install Python.
RUN cd python-src && make install | tee -a $LOGS_DIR/python.install.log
#RUN cp -a $PYTHON_INSTALL_DIR/lib/libpython${PYTHON_SOVERSION}.so "$JNI_LIBS"

# Download & install rubicon-java's Java & C parts. The *.py files in rubicon-java are
# incorporated into apps via app dependency management and are ABI-independent since
# they access the C library via `ctypes`.
#ADD downloads/rubicon-java/* .
#RUN mv rubicon-java-* rubicon-java-src
#RUN cd rubicon-java-src && \
#    LDFLAGS='-landroid -llog' PYTHON_CONFIG=$PYTHON_INSTALL_DIR/bin/python3-config make | tee -a $LOGS_DIR/rubicon.log
#RUN mv rubicon-java-src/build/librubicon.so $JNI_LIBS
#RUN mkdir -p /opt/python-build/app/libs/ && mv rubicon-java-src/build/rubicon.jar $APPROOT/app/libs/


# Create pythonhome.zip for this CPU architecture, filtering pythonhome.zip using pythonhome-excludes
# to remove the CPython test suite, etc.
#ARG COMPRESS_LEVEL
#ADD excludes/all/pythonhome-excludes /opt/python-build/
#RUN mkdir -p "$ASSETS_DIR/stdlib" && cd "$PYTHON_INSTALL_DIR" && zip -x@/opt/python-build/pythonhome-excludes -$COMPRESS_LEVEL -q "$ASSETS_DIR"/stdlib/pythonhome.${TARGET_ABI_SHORTNAME}.zip -r .
#RUN mkdir -p "$ASSETS_DIR/stdlib" && cd "$PYTHON_INSTALL_DIR"
# Rename the ZIP file to include its sha256sum. This enables fast, accurate
# cache validation/invalidation when the ZIP file reaches the Android device.
#RUN sha256sum "$ASSETS_DIR"/stdlib/pythonhome.${TARGET_ABI_SHORTNAME}.zip | cut -d' ' -f1 > /tmp/sum
#RUN mv "$ASSETS_DIR"/stdlib/pythonhome.${TARGET_ABI_SHORTNAME}.zip "$ASSETS_DIR"/stdlib/pythonhome.`cat /tmp/sum`.${TARGET_ABI_SHORTNAME}.zip


FROM toolchain as build_boost
RUN apt-get update -qq && apt-get -qq install git curl zip bash autoconf automake libtool pkg-config make openssh-server cmake
COPY --from=build_openssl /opt/python-build/built/openssl /opt/python-build/built/openssl
COPY --from=build_bz2 /opt/python-build/built/libbz2 /opt/python-build/built/libbz2
COPY --from=build_xz /opt/python-build/built/xz /opt/python-build/built/xz
COPY --from=build_libffi /opt/python-build/built/libffi /opt/python-build/built/libffi
COPY --from=build_sqlite /opt/python-build/built/sqlite /opt/python-build/built/sqlite
COPY --from=build_python $PYTHON_INSTALL_DIR $PYTHON_INSTALL_DIR

ENV ASSETS_DIR $APPROOT/assets
RUN mkdir -p "${ASSETS_DIR}"

ADD downloads/boost/* .
RUN unzip -q Boost-*.zip && rm -rf Boost-*.zip && mv Boost-* boost-src
RUN cd ./boost-src && ./build-android.sh $NDK --toolchain=llvm --arch=$TARGET_ABI_SHORTNAME --with-python=${PYTHON_INSTALL_DIR}/

ENV BOOST_INSTALL_DIR="$BUILD_HOME/built/boost"
RUN mkdir -p "$BOOST_INSTALL_DIR" "$BOOST_INSTALL_DIR/include" "$BOOST_INSTALL_DIR/lib"  
RUN mv ./boost-src/build/out/*/lib/* $BOOST_INSTALL_DIR/lib
RUN mv ./boost-src/build/out/*/include/boost*/* $BOOST_INSTALL_DIR/include


ADD downloads/zstd/* .
RUN unzip -q zstd-*.zip && rm -rf zstd-*.zip && mv zstd-* zstd-src
#RUN ./zstd-src/build/cmake
RUN cd ./zstd-src/build/cmake && mkdir ./$TARGET_ABI_SHORTNAME && cd ./$TARGET_ABI_SHORTNAME && cmake .. \
    -DCMAKE_TOOLCHAIN_FILE=$NDK/build/cmake/android.toolchain.cmake -DANDROID_ABI=$TARGET_ABI_SHORTNAME  \
    -DANDROID_PLATFORM=android-23 && make
#ADD "https://www.random.org/cgi-bin/randbyte?nbytes=10&format=h" /dev/null
ENV ZSTD_INSTALL_DIR="$BUILD_HOME/built/zstd"
RUN mkdir -p "$ZSTD_INSTALL_DIR" "$ZSTD_INSTALL_DIR/include" "$ZSTD_INSTALL_DIR/lib"  
RUN mv ./zstd-src/build/cmake/$TARGET_ABI_SHORTNAME/lib/libzstd* $ZSTD_INSTALL_DIR/lib
RUN cp -Rp ./zstd-src/lib/* $ZSTD_INSTALL_DIR/include
RUN cd $ZSTD_INSTALL_DIR/include && find . -type f  -not -name "*.h" | xargs rm -rf {}

#RUN curl "https://bootstrap.pypa.io/get-pip.py" -o "/opt/python-build/get-pip.py"
#RUN ${PYTHON_INSTALL_DIR}/bin/python3 /opt/python-build/get-pip.py

ARG COMPRESS_LEVEL
ADD excludes/all/pythonhome-excludes /opt/python-build/
RUN mkdir -p "$ASSETS_DIR/stdlib" && cd "$PYTHON_INSTALL_DIR" && zip -x@/opt/python-build/pythonhome-excludes -$COMPRESS_LEVEL -q "$ASSETS_DIR"/stdlib/pythonhome.${TARGET_ABI_SHORTNAME}.zip -r .

# SSHD (for debugging)
#RUN mkdir /var/run/sshd
#RUN echo 'root:THEPASSWORDYOUCREATED' | chpasswd
#RUN sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config
#RUN sed -i 's/#PasswordAuthentication/PasswordAuthentication/' /etc/ssh/sshd_config

# SSH login fix. Otherwise user is kicked off after login
#RUN sed 's@session\s*required\s*pam_loginuid.so@session optional pam_loginuid.so@g' -i /etc/pam.d/sshd

#EXPOSE 22
#CMD ["/usr/sbin/sshd", "-D"]

