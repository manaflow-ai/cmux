cmake_minimum_required(VERSION 3.20)

project(cmux_cpp_terminal_frontend LANGUAGES CXX)

option(CMUX_FRONTEND_BUILD_TESTS "Build deterministic fake-transport tests" ON)
set(
    CMUX_CPP_SDK_DIR
    "${CMAKE_CURRENT_LIST_DIR}/../../cpp"
    CACHE PATH
    "Path to a local cmux-tui C++ SDK checkout; leave empty to use find_package")

if(CMUX_CPP_SDK_DIR)
    get_filename_component(CMUX_CPP_SDK_DIR "${CMUX_CPP_SDK_DIR}" ABSOLUTE)
    if(NOT EXISTS "${CMUX_CPP_SDK_DIR}/CMakeLists.txt")
        message(FATAL_ERROR "CMUX_CPP_SDK_DIR does not contain the cmux C++ SDK")
    endif()
    set(CMUX_BUILD_TESTS OFF CACHE BOOL "" FORCE)
    add_subdirectory(
        "${CMUX_CPP_SDK_DIR}"
        "${CMAKE_CURRENT_BINARY_DIR}/cmux-sdk"
        EXCLUDE_FROM_ALL)
else()
    find_package(cmux-tui-sdk 1.0 CONFIG REQUIRED)
endif()

add_library(cmux_terminal_frontend_core src/frontend.cpp)
target_link_libraries(cmux_terminal_frontend_core PUBLIC cmux::sdk)
target_include_directories(
    cmux_terminal_frontend_core
    PUBLIC
        $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>)
target_compile_features(cmux_terminal_frontend_core PUBLIC cxx_std_20)

add_executable(cmux-cpp-terminal-frontend src/main.cpp)
target_link_libraries(cmux-cpp-terminal-frontend PRIVATE cmux_terminal_frontend_core)
target_compile_features(cmux-cpp-terminal-frontend PRIVATE cxx_std_20)

if(CMAKE_CXX_COMPILER_ID MATCHES "AppleClang|Clang|GNU")
    target_compile_options(
        cmux_terminal_frontend_core PRIVATE -Wall -Wextra -Wpedantic -Werror)
    target_compile_options(
        cmux-cpp-terminal-frontend PRIVATE -Wall -Wextra -Wpedantic -Werror)
endif()

if(CMUX_FRONTEND_BUILD_TESTS)
    enable_testing()
    add_executable(cmux-cpp-terminal-frontend-tests tests/frontend_test.cpp)
    target_link_libraries(
        cmux-cpp-terminal-frontend-tests PRIVATE cmux_terminal_frontend_core)
    target_compile_features(cmux-cpp-terminal-frontend-tests PRIVATE cxx_std_20)
    if(CMAKE_CXX_COMPILER_ID MATCHES "AppleClang|Clang|GNU")
        target_compile_options(
            cmux-cpp-terminal-frontend-tests
            PRIVATE -Wall -Wextra -Wpedantic -Werror)
    endif()
    add_test(
        NAME cmux-cpp-terminal-frontend
        COMMAND cmux-cpp-terminal-frontend-tests)
endif()
