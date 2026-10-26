// Checks cmux_host::Encode/Decode (CEFShim/src/chromium_host_wire.h) against
// the golden frame that ChromiumHostFrameTests.swift checks too, so the
// Swift and C++ sides of the Chromium host wire cannot drift
// (scripts/cmux-next/test-chromium-host-wire-cpp.sh).
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

#include "../src/chromium_host_helpers.h"
#include "../src/chromium_host_wire.h"

static const char kGolden[] =
    "05000000030000000a000000feffffffffffff7f0300000004000000ffffffff"
    "00001000000000000807060504030201010000000000000061004100efbeadde";

static int failures = 0;

static void Check(bool ok, const char* what) {
  if (!ok) {
    ++failures;
    std::fprintf(stderr, "FAIL %s\n", what);
  }
}

// The helper payloads (chromium_host_helpers.h): the same values
// ChromiumHostProcessMirrorTests.swift decodes.
static void HelperChecks() {
  using cmux_host::HelperIdentity;
  HelperIdentity gpu;
  Check(cmux_host::ParseHelperArgs({"/x/Helper (GPU)", "--type=gpu-process", "--lang=en"}, &gpu), "gpu argv parses");
  Check(gpu.type == "gpu-process" && gpu.sub_type.empty() && !gpu.extension && gpu.renderer_client_id == 0,
        "gpu identity");
  Check(cmux_host::HelperPayload(gpu) == "gpu-process", "gpu payload");

  HelperIdentity network;
  Check(cmux_host::ParseHelperArgs({"--type=utility", "--utility-sub-type=network.mojom.NetworkService"}, &network),
        "utility argv parses");
  Check(cmux_host::HelperPayload(network) == "utility\nnetwork.mojom.NetworkService", "utility payload has the sub type");

  HelperIdentity renderer;
  Check(cmux_host::ParseHelperArgs({"--type=renderer", "--renderer-client-id=12"}, &renderer), "renderer argv parses");
  Check(renderer.renderer_client_id == 12 && !renderer.extension, "renderer client id");
  HelperIdentity extension;
  Check(cmux_host::ParseHelperArgs({"--type=renderer", "--extension-process", "--renderer-client-id=3"}, &extension) &&
            extension.extension,
        "extension renderer");
  HelperIdentity none;
  Check(!cmux_host::ParseHelperArgs({"/Applications/cmux.app/Contents/MacOS/cmux", "--type="}, &none),
        "no type: not a helper (or not exec'd yet)");

  // KERN_PROCARGS2: argc 2, exec path, NUL padding, argv[0], argv[1], then the environment.
  const char raw[] = "\x02\x00\x00\x00/bin/h\x00\x00\x00/bin/h\x00--type=gpu-process\x00PATH=/bin\x00";
  const std::vector<std::string> argv =
      cmux_host::ParseProcArgs(reinterpret_cast<const uint8_t*>(raw), sizeof raw - 1);
  Check(argv.size() == 2 && argv[0] == "/bin/h" && argv[1] == "--type=gpu-process", "procargs: argv only");
  Check(cmux_host::ParseProcArgs(nullptr, 0).empty(), "procargs: empty buffer");

  const std::vector<int32_t> clients =
      cmux_host::RendererClients({"7-ABCDEF", "9-1234", "7-FFFF", "x-1", "-5", "0-1", "12"});
  Check(clients.size() == 2 && clients[0] == 7 && clients[1] == 9, "renderer clients: distinct, first seen order");
  const std::string encoded = cmux_host::EncodeClientIDs({7, 0x01020304});
  Check(encoded == std::string("\x07\x00\x00\x00\x04\x03\x02\x01", 8), "client ids: little-endian int32");

  // Raw wait statuses: SIGKILL (9), SIGSEGV with a core (0x8b), exit 3 (0x300), stopped (0x137f).
  Check(cmux_host::TerminatingSignal(9) == 9 && cmux_host::ExitCode(9) == 0, "SIGKILL status");
  Check(cmux_host::TerminatingSignal(0x8b) == 11, "SIGSEGV with core");
  Check(cmux_host::TerminatingSignal(0x300) == 0 && cmux_host::ExitCode(0x300) == 3, "exit 3");
  Check(cmux_host::TerminatingSignal(0x137f) == 0, "stopped is not a signal end");
  Check(cmux_host::kHelperStart == 109 && cmux_host::kHelperExit == 110 && cmux_host::kRendererClients == 111,
        "helper kinds match ChromiumHostFrame.Kind");
}

int main() {
  uint8_t golden[cmux_host::kHeaderSize];
  for (size_t i = 0; i < cmux_host::kHeaderSize; ++i) {
    unsigned value = 0;
    std::sscanf(kGolden + 2 * i, "%2x", &value);
    golden[i] = static_cast<uint8_t>(value);
  }
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

  HelperChecks();
  if (failures) return 1;
  std::printf("chromium_host_wire_test: ok\n");
  return 0;
}
