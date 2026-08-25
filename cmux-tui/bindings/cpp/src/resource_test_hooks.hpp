#pragma once

#include <cstddef>

#if !defined(CMUX_CPP_TESTING)
#error "resource test hooks are available only in C++ SDK test builds"
#endif

namespace cmux::detail {

void simulate_spurious_request_lock_failures(std::size_t count) noexcept;

[[nodiscard]] std::size_t
simulated_request_lock_failures_observed() noexcept;

[[nodiscard]] bool
consume_simulated_request_lock_failure() noexcept;

}  // namespace cmux::detail
