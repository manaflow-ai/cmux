cmake_minimum_required(VERSION 3.20)
project(cmux_conformance_cpp LANGUAGES CXX)

set(CMUX_BUILD_TESTS OFF CACHE BOOL "" FORCE)
add_subdirectory("../../../../cpp" cmux-sdk)
find_package(Threads REQUIRED)

add_executable(cmux-conformance-cpp main.cpp)
target_compile_features(cmux-conformance-cpp PRIVATE cxx_std_20)
target_link_libraries(cmux-conformance-cpp PRIVATE cmux::sdk Threads::Threads)
