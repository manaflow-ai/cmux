#include "cmux/base64.hpp"

#include <array>

namespace cmux {
namespace {

constexpr std::string_view alphabet =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

constexpr std::array<std::int16_t, 256> decode_table() {
    std::array<std::int16_t, 256> table{};
    table.fill(-1);
    for (std::size_t index = 0; index < alphabet.size(); ++index) {
        table[static_cast<unsigned char>(alphabet[index])] = static_cast<std::int16_t>(index);
    }
    return table;
}

constexpr auto decoded = decode_table();

}  // namespace

std::string base64_encode(std::span<const std::byte> input) {
    std::string output;
    output.reserve(((input.size() + 2) / 3) * 4);
    for (std::size_t offset = 0; offset < input.size(); offset += 3) {
        const auto first = std::to_integer<std::uint32_t>(input[offset]);
        const auto second =
            offset + 1 < input.size() ? std::to_integer<std::uint32_t>(input[offset + 1]) : 0U;
        const auto third =
            offset + 2 < input.size() ? std::to_integer<std::uint32_t>(input[offset + 2]) : 0U;
        const std::uint32_t value = (first << 16U) | (second << 8U) | third;
        output.push_back(alphabet[(value >> 18U) & 0x3fU]);
        output.push_back(alphabet[(value >> 12U) & 0x3fU]);
        output.push_back(offset + 1 < input.size() ? alphabet[(value >> 6U) & 0x3fU] : '=');
        output.push_back(offset + 2 < input.size() ? alphabet[value & 0x3fU] : '=');
    }
    return output;
}

Result<std::vector<std::byte>> base64_decode(
    std::string_view input,
    std::size_t max_decoded_bytes) {
    if (input.size() % 4 != 0) {
        return make_error(ErrorCode::decode, "base64 length must be divisible by four");
    }
    const std::size_t padding =
        input.empty() ? 0 : (input.back() == '=' ? (input.size() >= 2 && input[input.size() - 2] == '=' ? 2 : 1) : 0);
    const std::size_t decoded_size = (input.size() / 4) * 3 - padding;
    if (decoded_size > max_decoded_bytes) {
        return make_error(ErrorCode::decode, "decoded base64 exceeds configured limit");
    }

    std::vector<std::byte> output;
    output.reserve(decoded_size);
    for (std::size_t offset = 0; offset < input.size(); offset += 4) {
        std::uint32_t value = 0;
        bool saw_padding = false;
        for (std::size_t index = 0; index < 4; ++index) {
            const char ch = input[offset + index];
            if (ch == '=') {
                if (offset + 4 != input.size() || index < 2 ||
                    (index == 2 && input[offset + 3] != '=')) {
                    return make_error(ErrorCode::decode, "invalid base64 padding");
                }
                saw_padding = true;
                value <<= 6U;
                continue;
            }
            if (saw_padding) {
                return make_error(ErrorCode::decode, "invalid base64 padding");
            }
            const auto decoded_value = decoded[static_cast<unsigned char>(ch)];
            if (decoded_value < 0) {
                return make_error(ErrorCode::decode, "invalid base64 character");
            }
            value = (value << 6U) | static_cast<std::uint32_t>(decoded_value);
        }
        if (offset + 4 == input.size()) {
            if (padding == 1 && (value & 0x000000c0U) != 0) {
                return make_error(ErrorCode::decode, "non-canonical base64 padding bits");
            }
            if (padding == 2 && (value & 0x0000f000U) != 0) {
                return make_error(ErrorCode::decode, "non-canonical base64 padding bits");
            }
        }
        output.push_back(static_cast<std::byte>((value >> 16U) & 0xffU));
        if (output.size() < decoded_size) {
            output.push_back(static_cast<std::byte>((value >> 8U) & 0xffU));
        }
        if (output.size() < decoded_size) {
            output.push_back(static_cast<std::byte>(value & 0xffU));
        }
    }
    return output;
}

}  // namespace cmux
