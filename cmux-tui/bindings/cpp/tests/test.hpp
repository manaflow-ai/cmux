#pragma once

#include <functional>
#include <sstream>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

namespace test {

using Function = void (*)();

struct Case {
    std::string name;
    Function function;
};

inline std::vector<Case>& cases() {
    static std::vector<Case> value;
    return value;
}

struct Register {
    Register(std::string name, Function function) {
        cases().push_back(Case{std::move(name), function});
    }
};

[[noreturn]] inline void fail(
    const char* expression,
    const char* file,
    int line,
    std::string detail = {}) {
    std::ostringstream message;
    message << file << ':' << line << ": check failed: " << expression;
    if (!detail.empty()) {
        message << " (" << detail << ')';
    }
    throw std::runtime_error(message.str());
}

}  // namespace test

#define CMUX_TEST_CONCAT_INNER(a, b) a##b
#define CMUX_TEST_CONCAT(a, b) CMUX_TEST_CONCAT_INNER(a, b)
#define TEST(name)                                                                    \
    static void CMUX_TEST_CONCAT(test_function_, __LINE__)();                         \
    static ::test::Register CMUX_TEST_CONCAT(test_registration_, __LINE__)(           \
        name, &CMUX_TEST_CONCAT(test_function_, __LINE__));                            \
    static void CMUX_TEST_CONCAT(test_function_, __LINE__)()
#define CHECK(expression)                                                              \
    do {                                                                               \
        if (!(expression)) {                                                           \
            ::test::fail(#expression, __FILE__, __LINE__);                             \
        }                                                                              \
    } while (false)
#define CHECK_EQ(left, right)                                                          \
    do {                                                                               \
        const auto cmux_left = (left);                                                 \
        const auto cmux_right = (right);                                               \
        if (!(cmux_left == cmux_right)) {                                              \
            ::test::fail(#left " == " #right, __FILE__, __LINE__);                    \
        }                                                                              \
    } while (false)
