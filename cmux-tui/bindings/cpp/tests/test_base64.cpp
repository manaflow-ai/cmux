#include "test.hpp"

#include <array>
#include <cstddef>
#include <string>

#include "cmux/base64.hpp"

TEST("base64 codec round trips binary payloads") {
    const std::array input{
        std::byte{0x00}, std::byte{0x01}, std::byte{0xfe}, std::byte{0xff}, std::byte{0x42}};
    const auto encoded = cmux::base64_encode(input);
    CHECK_EQ(encoded, std::string("AAH+/0I="));
    auto decoded = cmux::base64_decode(encoded);
    CHECK(decoded);
    CHECK_EQ(decoded.value().size(), input.size());
    CHECK(std::equal(decoded.value().begin(), decoded.value().end(), input.begin()));
}

TEST("base64 decoder rejects malformed and oversized input") {
    CHECK(!cmux::base64_decode("abc"));
    CHECK(!cmux::base64_decode("!!!!"));
    CHECK(!cmux::base64_decode("AAAA", 2));
    CHECK(!cmux::base64_decode("A=AA"));
    CHECK(!cmux::base64_decode("AB=="));
    CHECK(!cmux::base64_decode("AAB="));
}
