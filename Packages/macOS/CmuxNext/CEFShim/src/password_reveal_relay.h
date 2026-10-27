// Relays one revealed password from the fork's cmux_password_reveal callback
// to the app (plans/cmux-next/passwords.md 1.4). No CEF needed, so
// CEFShim/tests/password_reveal_relay_test.cpp compiles it alone
// (scripts/cmux-next/test-password-reveal-relay-cpp.sh).
//
// The bytes never go through Emit (a std::string and the event queue, which
// nothing zeroes). The shim copies them into a buffer it owns, calls the
// app's `done` with that buffer (the app copies it into SecretBytes during
// the call), then zeroes the buffer before it is freed.
#ifndef CMUX_SHIM_PASSWORD_REVEAL_RELAY_H_
#define CMUX_SHIM_PASSWORD_REVEAL_RELAY_H_

#include <cstddef>
#include <string_view>
#include <vector>

namespace cmux_shim {

using PasswordRevealFn = void (*)(void* ctx, const char* password, size_t length);

// Zeroes `bytes` with volatile stores, which the compiler may not drop as dead.
inline void ZeroSecret(std::vector<char>& bytes) {
  for (char& byte : bytes) {
    volatile char& slot = byte;
    slot = 0;
  }
}

// Calls done(ctx, copy, length) once; NULL and 0 when there is no password.
// `after_zero` (tests only) sees the shim's buffer after it was zeroed.
inline void RelayRevealedPassword(const char* bytes, size_t length, PasswordRevealFn done, void* ctx,
                                  void (*after_zero)(const char* buffer, size_t length) = nullptr) {
  if (!done) return;
  if (!bytes || length == 0) {
    done(ctx, nullptr, 0);
    return;
  }
  const std::string_view revealed(bytes, length);
  std::vector<char> copy(revealed.begin(), revealed.end());
  done(ctx, copy.data(), copy.size());
  ZeroSecret(copy);
  if (after_zero) after_zero(copy.data(), copy.size());
}

}  // namespace cmux_shim

#endif  // CMUX_SHIM_PASSWORD_REVEAL_RELAY_H_
