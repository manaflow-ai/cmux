#pragma once

#include <filesystem>
#include <string>
#include <string_view>

namespace cmux::detail {

[[nodiscard]] inline bool is_hashed_socket_path_for_uid(
    std::string_view socket_path,
    unsigned long uid) {
    const auto parent_component =
        std::filesystem::path(socket_path).parent_path().filename();
    return parent_component ==
        std::filesystem::path("cmux-tui-hashed-" + std::to_string(uid));
}

}  // namespace cmux::detail
