// Cases of RENDER_TERMINATED's request (CEFShim/src/renderer_end.h):
// scripts/cmux-next/test-shim-renderer-end-cpp.sh. The first browser of a renderer's end reports it,
// the others it hosted say it is shared, and after the end's task the next end is new.
#include "../src/renderer_end.h"

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
  using cmux_shim::RendererClientIdOf;
  using cmux_shim::RendererEnds;

  Expect(RendererClientIdOf("12-ABCDEF0123456789") == 12, "the host id before the dash");
  Expect(RendererClientIdOf("7-1") == 7, "a one-digit host id");
  Expect(RendererClientIdOf("-12") == 0, "no host id before the dash");
  Expect(RendererClientIdOf("12") == 0, "no dash");
  Expect(RendererClientIdOf("1a-2") == 0, "a host id that is not a number");
  Expect(RendererClientIdOf("0-2") == 0, "host id 0 names no process");
  Expect(RendererClientIdOf("9999999999-2") == 0, "a host id too large for an int");
  Expect(RendererClientIdOf("") == 0, "an empty identifier");

  RendererEnds ends;
  Expect(ends.Report(12) == cmux_shim::kRendererEndFirst, "the first browser of an end reports it");
  Expect(ends.Report(12) == cmux_shim::kRendererEndShared, "a second browser of the same renderer shares it");
  Expect(ends.Report(12) == cmux_shim::kRendererEndShared, "a third one too");
  Expect(ends.Report(13) == cmux_shim::kRendererEndFirst, "another renderer's end in the same task is its own");
  Expect(ends.Report(0) == cmux_shim::kRendererEndUnknown, "no process: unknown");
  Expect(ends.Report(0) == cmux_shim::kRendererEndUnknown, "unknown stays unknown");
  ends.Forget(12);
  Expect(ends.Report(12) == cmux_shim::kRendererEndFirst, "the relaunched host's next end is new");
  Expect(ends.Report(13) == cmux_shim::kRendererEndShared, "forgetting one renderer keeps the other");

  if (failures == 0) std::printf("renderer end: all cases passed\n");
  return failures == 0 ? 0 : 1;
}
