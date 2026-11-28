cmake_minimum_required(VERSION 3.20)

project(cmux_tui_sdk VERSION 1.0.0 LANGUAGES CXX)

include(CMakePackageConfigHelpers)
include(GNUInstallDirs)

option(CMUX_BUILD_TESTS "Build the cmux-tui C++ SDK tests" ${PROJECT_IS_TOP_LEVEL})

find_package(Threads REQUIRED)

add_library(cmux_tui_sdk
    src/base64.cpp
    src/json.cpp
    src/resource.cpp
    src/resource_models.cpp
    src/raw/attachment.cpp
    src/raw/client_core.cpp
    src/raw/generated/protocol.cpp
    src/unix_transport.cpp
)
add_library(cmux::sdk ALIAS cmux_tui_sdk)

target_compile_features(cmux_tui_sdk PUBLIC cxx_std_20)
target_link_libraries(cmux_tui_sdk PUBLIC Threads::Threads)
target_include_directories(cmux_tui_sdk
    PUBLIC
        $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
        $<INSTALL_INTERFACE:${CMAKE_INSTALL_INCLUDEDIR}>
    PRIVATE
        ${CMAKE_CURRENT_SOURCE_DIR}/src
)
set_target_properties(cmux_tui_sdk PROPERTIES
    CXX_EXTENSIONS OFF
    EXPORT_NAME sdk
    POSITION_INDEPENDENT_CODE ON
    VERSION ${PROJECT_VERSION}
    SOVERSION ${PROJECT_VERSION_MAJOR}
)

if(CMAKE_CXX_COMPILER_ID MATCHES "AppleClang|Clang|GNU")
    target_compile_options(cmux_tui_sdk PRIVATE -Wall -Wextra -Wpedantic -Wconversion)
endif()

install(TARGETS cmux_tui_sdk
    EXPORT cmux-tui-sdk-targets
    ARCHIVE DESTINATION ${CMAKE_INSTALL_LIBDIR}
    LIBRARY DESTINATION ${CMAKE_INSTALL_LIBDIR}
    RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR}
    INCLUDES DESTINATION ${CMAKE_INSTALL_INCLUDEDIR}
)
install(DIRECTORY include/ DESTINATION ${CMAKE_INSTALL_INCLUDEDIR})
install(EXPORT cmux-tui-sdk-targets
    FILE cmux-tui-sdk-targets.cmake
    NAMESPACE cmux::
    DESTINATION ${CMAKE_INSTALL_LIBDIR}/cmake/cmux-tui-sdk
)

configure_package_config_file(
    cmake/cmux-tui-sdk-config.cmake.in
    ${CMAKE_CURRENT_BINARY_DIR}/cmux-tui-sdk-config.cmake
    INSTALL_DESTINATION ${CMAKE_INSTALL_LIBDIR}/cmake/cmux-tui-sdk
)
write_basic_package_version_file(
    ${CMAKE_CURRENT_BINARY_DIR}/cmux-tui-sdk-config-version.cmake
    VERSION ${PROJECT_VERSION}
    COMPATIBILITY SameMajorVersion
)
install(FILES
    ${CMAKE_CURRENT_BINARY_DIR}/cmux-tui-sdk-config.cmake
    ${CMAKE_CURRENT_BINARY_DIR}/cmux-tui-sdk-config-version.cmake
    DESTINATION ${CMAKE_INSTALL_LIBDIR}/cmake/cmux-tui-sdk
)

if(CMUX_BUILD_TESTS)
    enable_testing()
    target_compile_definitions(cmux_tui_sdk PRIVATE CMUX_CPP_TESTING=1)
    add_executable(cmux_cpp_tests
        tests/test_main.cpp
        tests/test_attachment.cpp
        tests/test_base64.cpp
        tests/test_client.cpp
        tests/test_generated.cpp
        tests/test_json.cpp
        tests/test_macro_collision.cpp
        tests/test_resource.cpp
        tests/test_unix_transport.cpp
    )
    target_link_libraries(cmux_cpp_tests PRIVATE cmux::sdk Threads::Threads)
    target_compile_features(cmux_cpp_tests PRIVATE cxx_std_20)
    target_compile_definitions(cmux_cpp_tests PRIVATE CMUX_CPP_TESTING=1)
    target_include_directories(cmux_cpp_tests PRIVATE src)
    if(CMAKE_CXX_COMPILER_ID MATCHES "AppleClang|Clang|GNU")
        target_compile_options(cmux_cpp_tests PRIVATE -Wall -Wextra -Wpedantic -Werror)
    endif()
    add_test(NAME cmux-cpp-unit COMMAND cmux_cpp_tests)

    add_test(
        NAME cmux-cpp-package-consumer
        COMMAND ${CMAKE_COMMAND}
            -DSDK_BINARY_DIR=${CMAKE_CURRENT_BINARY_DIR}
            -DSDK_SOURCE_DIR=${CMAKE_CURRENT_SOURCE_DIR}
            -DTEST_ROOT=${CMAKE_CURRENT_BINARY_DIR}/package-consumer
            -DCONFIGURATION=$<CONFIG>
            -P ${CMAKE_CURRENT_SOURCE_DIR}/tests/package_consumer.cmake
    )
endif()
