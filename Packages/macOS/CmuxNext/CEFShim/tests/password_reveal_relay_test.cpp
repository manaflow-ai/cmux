// Checks cmux_shim::RelayRevealedPassword (CEFShim/src/password_reveal_relay.h):
// the app sees the password once, during the call, and the shim's own copy is
// zero after it (scripts/cmux-next/test-password-reveal-relay-cpp.sh).
#include <cstring>
#include <iostream>
#include <string>

#include "../src/password_reveal_relay.h"

static int g_cases = 0;
static int g_failures = 0;

static void Expect(bool ok, const char* what) {
  ++g_cases;
  if (!ok) {
    ++g_failures;
    std::cerr << "FAIL " << what << "\n";
  }
}

struct Seen {
  int calls = 0;
  std::string bytes;
  bool null_password = false;
  const char* buffer = nullptr;
};

static void Done(void* ctx, const char* password, size_t length) {
  auto* seen = static_cast<Seen*>(ctx);
  ++seen->calls;
  seen->null_password = password == nullptr;
  seen->buffer = password;
  if (password) seen->bytes.assign(password, length);
}

static bool g_zeroed = false;
static const char* g_zero_buffer = nullptr;
static void AfterZero(const char* buffer, size_t length) {
  g_zero_buffer = buffer;
  g_zeroed = length > 0;
  for (size_t i = 0; i < length; ++i) g_zeroed = g_zeroed && buffer[i] == 0;
}

int main() {
  const char fork_bytes[] = "cmux-test-secret-\xC3\xA9";
  Seen seen;
  cmux_shim::RelayRevealedPassword(fork_bytes, sizeof(fork_bytes) - 1, &Done, &seen, &AfterZero);
  Expect(seen.calls == 1, "done runs once");
  Expect(seen.bytes == std::string(fork_bytes, sizeof(fork_bytes) - 1), "done sees the exact bytes (no terminator needed)");
  Expect(seen.buffer != fork_bytes, "done gets the shim's copy, not the fork's buffer");
  Expect(g_zero_buffer == seen.buffer, "the zeroed buffer is the one done saw");
  Expect(g_zeroed, "the shim's copy is zero after done returns");

  Seen none;
  cmux_shim::RelayRevealedPassword(nullptr, 0, &Done, &none);
  Expect(none.calls == 1 && none.null_password, "not found: done(NULL, 0) once");

  cmux_shim::RelayRevealedPassword(fork_bytes, 3, nullptr, nullptr);
  Expect(true, "a missing done does not crash");

  std::cout << g_cases << " cases, " << g_failures << " failures\n";
  return g_failures == 0 ? 0 : 1;
}
