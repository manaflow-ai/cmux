#pragma once

#include <cstddef>
#include <cstdint>
#include <span>
#include <string>
#include <string_view>
#include <vector>

#include "cmux/result.hpp"

namespace cmux {

[[nodiscard]] std::string base64_encode(std::span<const std::byte> input);
[[nodiscard]] Result<std::vector<std::byte>> base64_decode(
    std::string_view input,
    std::size_t max_decoded_bytes = 16U * 1024U * 1024U);

}  // namespace cmux
