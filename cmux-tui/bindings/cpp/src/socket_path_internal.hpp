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
    // A trailing separator denotes the hashed directory itself, not a socket
    // path. Reject it before comparing the parent component.
    if (socket_path.empty() || socket_path.back() == '/') {
        return false;
    }
    return parent_component ==
        std::filesystem::path("cmux-tui-hashed-" + std::to_string(uid));
}

}  // namespace cmux::detail
