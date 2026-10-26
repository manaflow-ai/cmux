// Checks cmux_host::Encode/Decode (CEFShim/src/chromium_host_wire.h) against
// the golden frame that ChromiumHostFrameTests.swift checks too, so the
// Swift and C++ sides of the Chromium host wire cannot drift
// (scripts/cmux-next/test-chromium-host-wire-cpp.sh).
#include <cstdio>
#include <cstring>
#include <string>

#include "../src/chromium_host_wire.h"

static const char kGolden[] =
    "05000000030000000a000000feffffffffffff7f0300000004000000ffffffff"
    "00001000000000000807060504030201010000000000000061004100efbeadde";

// kEnergySaver version 1, on: the same bytes as ChromiumHostFrameTests.energySaverGolden.
static const char kEnergySaverGolden[] =
    "0b00000000000000010000000100000000000000000000000000000000000000"
    "0000000000000000000000000000000000000000000000000000000000000000";

static int failures = 0;

static void Unhex(const char* hex, uint8_t out[cmux_host::kHeaderSize]) {
  for (size_t i = 0; i < cmux_host::kHeaderSize; ++i) {
    unsigned value = 0;
    std::sscanf(hex + 2 * i, "%2x", &value);
    out[i] = static_cast<uint8_t>(value);
  }
}

static void Check(bool ok, const char* what) {
  if (!ok) {
    ++failures;
    std::fprintf(stderr, "FAIL %s\n", what);
  }
}

int main() {
  uint8_t golden[cmux_host::kHeaderSize];
  Unhex(kGolden, golden);
  cmux_host::Header h;
  h.kind = cmux_host::kKey;
  h.payload = 3;
  h.v[0] = 10;
  h.v[1] = -2;
  h.v[2] = 0x7fffffff;
  h.v[3] = 3;
  h.v[4] = 4;
  h.v[5] = -1;
  h.flags = 0x100000;
  h.t0 = 0x0102030405060708ULL;
  h.t1 = 1;
  h.ch = 0x61;
  h.unmod = 0x41;
  h.seq = 0xdeadbeef;
  uint8_t encoded[cmux_host::kHeaderSize];
  cmux_host::Encode(h, encoded);
  Check(std::memcmp(encoded, golden, sizeof golden) == 0, "encode matches the golden frame");

  cmux_host::Header d;
  Check(cmux_host::Decode(golden, &d), "golden frame decodes");
  Check(d.kind == cmux_host::kKey && d.payload == 3, "kind and payload");
  Check(d.v[0] == 10 && d.v[1] == -2 && d.v[2] == 0x7fffffff && d.v[5] == -1, "signed values");
  Check(d.flags == 0x100000 && d.t0 == 0x0102030405060708ULL && d.t1 == 1, "flags and times");
  Check(d.ch == 0x61 && d.unmod == 0x41 && d.seq == 0xdeadbeef, "characters and seq");

  cmux_host::Header big;
  big.payload = cmux_host::kMaxPayload + 1;
  uint8_t too_long[cmux_host::kHeaderSize];
  cmux_host::Encode(big, too_long);
  Check(!cmux_host::Decode(too_long, &d), "a payload over the limit is refused");

  uint8_t saver_golden[cmux_host::kHeaderSize];
  Unhex(kEnergySaverGolden, saver_golden);
  cmux_host::Header saver;
  saver.kind = cmux_host::kEnergySaver;
  saver.v[0] = cmux_host::kEnergySaverVersion;
  saver.v[1] = 1;
  uint8_t saver_encoded[cmux_host::kHeaderSize];
  cmux_host::Encode(saver, saver_encoded);
  Check(std::memcmp(saver_encoded, saver_golden, sizeof saver_golden) == 0, "energy saver frame matches its golden");

  if (failures) return 1;
  std::printf("chromium_host_wire_test: ok\n");
  return 0;
}
