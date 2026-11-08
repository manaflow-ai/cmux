#include "test.hpp"

#include <exception>
#include <iostream>

int main() {
    int failures = 0;
    for (const auto& test : test::cases()) {
        try {
            test.function();
            std::cout << "ok: " << test.name << '\n';
        } catch (const std::exception& error) {
            ++failures;
            std::cerr << "FAIL: " << test.name << ": " << error.what() << '\n';
        } catch (...) {
            ++failures;
            std::cerr << "FAIL: " << test.name << ": unknown exception\n";
        }
    }
    if (failures != 0) {
        std::cerr << failures << " test(s) failed\n";
    }
    return failures == 0 ? 0 : 1;
}
