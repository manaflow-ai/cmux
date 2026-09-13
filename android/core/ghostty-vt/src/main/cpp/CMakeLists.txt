cmake_minimum_required(VERSION 3.22.1)
project(ghostty_vt_jni)

# Path to the ghostty submodule at the repo root (android/core/ghostty-vt/src/main/cpp -> repo root).
set(GHOSTTY_ROOT ${CMAKE_CURRENT_SOURCE_DIR}/../../../../../../ghostty)

# Prebuilt libghostty-vt.so.<N>, one per ABI, built by
# android/scripts/build-ghostty-vt.sh and committed under src/main/jniLibs/<abi>/.
# This is NOT built by this CMake project — only the small JNI glue below is
# compiled by the normal Gradle/NDK build.
#
# The installed filename must exactly match the library's own embedded SONAME
# (Zig's addLibrary() versions this, e.g. "libghostty-vt.so.0") — Android's
# dynamic linker resolves this JNI lib's NEEDED entry by that literal filename
# at runtime, not by whatever name it happened to be linked under here. The
# build script installs it under its real SONAME already; glob instead of
# hardcoding "libghostty-vt.so" so a future Ghostty version bump (which could
# change the embedded SONAME) doesn't silently break this again.
file(GLOB GHOSTTY_VT_LIB "${CMAKE_CURRENT_SOURCE_DIR}/../jniLibs/${ANDROID_ABI}/libghostty-vt.so*")
list(LENGTH GHOSTTY_VT_LIB GHOSTTY_VT_LIB_COUNT)
if(NOT GHOSTTY_VT_LIB_COUNT EQUAL 1)
    message(FATAL_ERROR "Expected exactly one libghostty-vt.so* in jniLibs/${ANDROID_ABI}, found: ${GHOSTTY_VT_LIB}. Run android/scripts/build-ghostty-vt.sh.")
endif()

add_library(ghostty-vt SHARED IMPORTED)
set_target_properties(ghostty-vt PROPERTIES
    IMPORTED_LOCATION ${GHOSTTY_VT_LIB}
)

add_library(ghostty_vt_jni SHARED
    ghostty_vt_jni.cpp
)

target_include_directories(ghostty_vt_jni PRIVATE
    ${GHOSTTY_ROOT}/include
)

target_link_libraries(ghostty_vt_jni
    ghostty-vt
    log
)
