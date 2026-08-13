if(NOT DEFINED SDK_BINARY_DIR OR NOT DEFINED SDK_SOURCE_DIR OR NOT DEFINED TEST_ROOT)
    message(FATAL_ERROR "package consumer test is missing required paths")
endif()

file(REMOVE_RECURSE "${TEST_ROOT}")
file(MAKE_DIRECTORY "${TEST_ROOT}")
set(INSTALL_ROOT "${TEST_ROOT}/install")
set(CONSUMER_BUILD "${TEST_ROOT}/build")

set(INSTALL_COMMAND
    "${CMAKE_COMMAND}" --install "${SDK_BINARY_DIR}" --prefix "${INSTALL_ROOT}"
)
if(DEFINED CONFIGURATION AND NOT CONFIGURATION STREQUAL "")
    list(APPEND INSTALL_COMMAND --config "${CONFIGURATION}")
endif()
execute_process(COMMAND ${INSTALL_COMMAND} RESULT_VARIABLE INSTALL_RESULT)
if(NOT INSTALL_RESULT EQUAL 0)
    message(FATAL_ERROR "SDK install failed with exit code ${INSTALL_RESULT}")
endif()

execute_process(
    COMMAND
        "${CMAKE_COMMAND}"
        -S "${SDK_SOURCE_DIR}/tests/consumer"
        -B "${CONSUMER_BUILD}"
        "-DCMAKE_PREFIX_PATH=${INSTALL_ROOT}"
    RESULT_VARIABLE CONFIGURE_RESULT
)
if(NOT CONFIGURE_RESULT EQUAL 0)
    message(FATAL_ERROR "consumer configure failed with exit code ${CONFIGURE_RESULT}")
endif()

execute_process(
    COMMAND "${CMAKE_COMMAND}" --build "${CONSUMER_BUILD}" --config "${CONFIGURATION}"
    RESULT_VARIABLE BUILD_RESULT
)
if(NOT BUILD_RESULT EQUAL 0)
    message(FATAL_ERROR "consumer build failed with exit code ${BUILD_RESULT}")
endif()
