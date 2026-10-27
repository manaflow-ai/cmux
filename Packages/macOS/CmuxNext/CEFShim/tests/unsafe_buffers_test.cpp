// Checks CEFShim/src/unsafe_buffers.h: C ABI arrays as spans, and the bounded
// C string writers that replaced snprintf, strdup and memcpy in the shim
// (scripts/cmux-next/test-shim-unsafe-buffers-cpp.sh).
#include <array>
#include <cstdlib>
#include <iostream>
#include <string>
#include <string_view>

#include "../src/unsafe_buffers.h"

static int failures = 0;
static int cases = 0;

static void Expect(bool ok, const char* what) {
  ++cases;
  if (!ok) {
    ++failures;
    std::cerr << "FAIL " << what << "\n";
  }
}

static void Spans() {
  std::array<int, 3> values = {1, 2, 3};
  // SAFETY: `values` holds 3 ints.
  const std::span<int> all = UNSAFE_BUFFERS(cmux_shim::SpanFromCArray(values.data(), 3));
  Expect(all.size() == 3 && all.data() == values.data(), "a positive count covers the array");
  // SAFETY: an empty span is built for a NULL array whatever the count.
  Expect(UNSAFE_BUFFERS(cmux_shim::SpanFromCArray(static_cast<int*>(nullptr), 5)).empty(), "NULL is empty");
  // SAFETY: a negative count builds an empty span.
  Expect(UNSAFE_BUFFERS(cmux_shim::SpanFromCArray(values.data(), -1)).empty(), "a negative count is empty");
  // SAFETY: a zero count builds an empty span.
  Expect(UNSAFE_BUFFERS(cmux_shim::SpanFromCArray(values.data(), size_t{0})).empty(), "a zero size_t count is empty");
}

static void CStrings() {
  std::array<char, 8> out;
  out.fill('x');
  cmux_shim::WriteCString(out, "short");
  Expect(std::string_view(out.data()) == "short", "a string that fits is copied with its NUL");

  out.fill('x');
  cmux_shim::WriteCString(out, "much longer than eight");
  Expect(std::string_view(out.data()) == "much lo" && out[7] == '\0', "a long string is cut as snprintf cuts it");

  out.fill('x');
  cmux_shim::WriteCString(std::span<char>(out).first(0), "anything");
  Expect(out[0] == 'x', "an empty buffer is left alone");

  constexpr std::string_view kEmbeddedNul("a\0b", 3);
  char* owned = cmux_shim::OwnedCString(kEmbeddedNul);
  Expect(owned && std::string_view(owned, 4) == std::string_view("a\0b\0", 4),
         "an owned copy keeps every byte and ends with NUL");
  std::free(owned);
  owned = cmux_shim::OwnedCString("");
  Expect(owned && std::string_view(owned, 1) == std::string_view("\0", 1), "an owned copy of nothing is an empty string");
  std::free(owned);
}

int main() {
  Spans();
  CStrings();
  std::cout << cases << " cases, " << failures << " failures\n";
  return failures ? 1 : 0;
}
