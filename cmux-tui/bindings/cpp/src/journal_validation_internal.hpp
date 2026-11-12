#pragma once

#include <algorithm>
#include <cstddef>
#include <string_view>

#include "cmux/resource.hpp"

namespace cmux::journal_detail {

[[nodiscard]] inline bool valid_journal_class(JournalClass value) noexcept {
    switch (value) {
        case JournalClass::state:
        case JournalClass::observation:
        case JournalClass::effect:
        case JournalClass::checkpoint:
            return true;
    }
    return false;
}

[[nodiscard]] inline bool valid_journal_replay(
    JournalReplayPolicy value) noexcept {
    switch (value) {
        case JournalReplayPolicy::required:
        case JournalReplayPolicy::advisory:
        case JournalReplayPolicy::never:
            return true;
    }
    return false;
}

[[nodiscard]] inline bool valid_journal_sensitivity(
    JournalSensitivity value) noexcept {
    switch (value) {
        case JournalSensitivity::public_:
        case JournalSensitivity::metadata:
        case JournalSensitivity::sensitive:
        case JournalSensitivity::secret:
            return true;
    }
    return false;
}

[[nodiscard]] inline unsigned sensitivity_rank(JournalSensitivity value) noexcept {
    switch (value) {
        case JournalSensitivity::public_: return 0;
        case JournalSensitivity::metadata: return 1;
        case JournalSensitivity::sensitive: return 2;
        case JournalSensitivity::secret: return 3;
    }
    return 3;
}

[[nodiscard]] inline bool valid_component(std::string_view value) noexcept {
    if (value.empty() || value.size() > 64 ||
        !((value.front() >= 'a' && value.front() <= 'z') ||
          (value.front() >= '0' && value.front() <= '9'))) {
        return false;
    }
    return std::all_of(value.begin(), value.end(), [](char byte) {
        return (byte >= 'a' && byte <= 'z') ||
               (byte >= '0' && byte <= '9') || byte == '_' || byte == '-';
    });
}

[[nodiscard]] inline bool valid_kind(std::string_view value) noexcept {
    if (value.empty() || value.size() > 128) return false;
    std::size_t start = 0;
    while (start < value.size()) {
        const auto dot = value.find('.', start);
        const auto end = dot == std::string_view::npos ? value.size() : dot;
        if (!valid_component(value.substr(start, end - start))) return false;
        if (dot == std::string_view::npos) return true;
        start = dot + 1;
    }
    return false;
}

}  // namespace cmux::journal_detail
