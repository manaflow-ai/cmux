cmake_minimum_required(VERSION 3.20)
project(cmux_tui_sdk_consumer LANGUAGES CXX)

find_package(cmux-tui-sdk 1.0 CONFIG REQUIRED)

add_executable(consumer main.cpp)
target_link_libraries(consumer PRIVATE cmux::sdk)
target_compile_features(consumer PRIVATE cxx_std_20)
