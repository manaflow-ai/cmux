cmake_minimum_required(VERSION 3.20)

project(cmux_resource_conformance_cpp LANGUAGES CXX)

set(CMUX_BUILD_TESTS OFF CACHE BOOL "" FORCE)
add_subdirectory(
    "${CMAKE_CURRENT_LIST_DIR}/../../../cpp"
    "${CMAKE_CURRENT_BINARY_DIR}/cmux-sdk"
)

add_executable(cmux-resource-conformance-cpp main.cpp)
target_link_libraries(cmux-resource-conformance-cpp PRIVATE cmux::sdk)
target_compile_features(cmux-resource-conformance-cpp PRIVATE cxx_std_20)

if(CMAKE_CXX_COMPILER_ID MATCHES "AppleClang|Clang|GNU")
    target_compile_options(
        cmux-resource-conformance-cpp
        PRIVATE
            -Wall
            -Wextra
            -Wpedantic
    )
endif()
