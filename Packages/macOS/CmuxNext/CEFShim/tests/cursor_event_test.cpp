// Cases of the CURSOR event's numbers (CEFShim/src/cursor_event.h):
// scripts/cmux-next/test-shim-cursor-cpp.sh. A custom cursor image goes on the
// wire only within Chromium's size limit; its scale and hotspot pack into the
// event the way CEFPageCursor.swift reads them back.
#include "../src/cursor_event.h"

#include <cmath>
#include <cstdio>

namespace {
int failures = 0;
void Expect(bool ok, const char* what) {
  if (!ok) {
    std::fprintf(stderr, "FAIL: %s\n", what);
    ++failures;
  }
}
}  // namespace

int main() {
  using cmux_shim::CustomCursorAllowed;
  using cmux_shim::CustomCursorFieldsFor;
  const unsigned char pixels[4] = {0, 0, 0, 0};

  Expect(CustomCursorAllowed(32, 32, pixels), "a 32 px image goes on the wire");
  Expect(CustomCursorAllowed(1024, 1, pixels), "a side of 1024 px is the limit, allowed");
  Expect(!CustomCursorAllowed(1025, 8, pixels), "a side over 1024 px is refused");
  Expect(!CustomCursorAllowed(0, 8, pixels), "an empty image is refused");
  Expect(!CustomCursorAllowed(8, -1, pixels), "a negative size is refused");
  Expect(!CustomCursorAllowed(8, 8, nullptr), "an image without pixels is refused");

  const auto two = CustomCursorFieldsFor(2.0f, 6, 9, 64, 64);
  Expect(two.scale_milli == 2000, "scale 2 is 2000");
  Expect((two.hotspot & 0xffffffff) == 6, "hotspot x in the low 32 bits");
  Expect((two.hotspot >> 32) == 9, "hotspot y in the high 32 bits");

  Expect(CustomCursorFieldsFor(1.5f, 0, 0, 8, 8).scale_milli == 1500, "a fractional scale keeps its milli");
  Expect(CustomCursorFieldsFor(0.0f, 0, 0, 8, 8).scale_milli == 1000, "scale 0 counts as 1, as Chrome's");
  Expect(CustomCursorFieldsFor(std::nanf(""), 0, 0, 8, 8).scale_milli == 1000, "a NaN scale counts as 1");
  Expect(CustomCursorFieldsFor(-2.0f, 0, 0, 8, 8).scale_milli == 1000, "a negative scale counts as 1");

  const auto outside = CustomCursorFieldsFor(1.0f, 40, -3, 16, 16);
  Expect((outside.hotspot & 0xffffffff) == 15, "a hotspot right of the image is clamped to its last column");
  Expect((outside.hotspot >> 32) == 0, "a hotspot above the image is clamped to its first row");

  const auto big = CustomCursorFieldsFor(8.0f, 1023, 1023, 1024, 1024);
  Expect((big.hotspot & 0xffffffff) == 1023 && (big.hotspot >> 32) == 1023, "the largest hotspot round-trips");
  Expect(big.hotspot >= 0, "the packed hotspot is never negative");

  if (failures == 0) std::printf("cursor event: all cases passed\n");
  return failures == 0 ? 0 : 1;
}
