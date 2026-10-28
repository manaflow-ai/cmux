// Cases of CMUX_SHIM_FRAME_RENDERERS (CEFShim/src/frame_renderers.h):
// scripts/cmux-next/tests/shim-frame-renderers.test.sh. A burst of frame changes posts one check, and
// only a new set of renderers is reported.
#include "../src/frame_renderers.h"

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
  cmux_shim::FrameRenderers renderers;

  Expect(renderers.Changed(3), "the first change posts the check");
  Expect(!renderers.Changed(3) && !renderers.Changed(3), "the changes of the same task wait for it");
  Expect(renderers.Changed(4), "another browser posts its own");
  Expect(renderers.Check(3, {7}), "the first check reports");
  Expect(!renderers.Pending(3), "the check ends the wait");

  // An iframe of another site added after the page's load: its renderer is new.
  renderers.Changed(3);
  Expect(renderers.Check(3, {7, 9}), "an out-of-process iframe's renderer is reported");
  // A same-site iframe in the main frame's renderer, or a frame whose renderer is not known yet.
  renderers.Changed(3);
  Expect(!renderers.Check(3, {7, 7, 9, 0}), "the same set is not reported again, in any order");
  renderers.Changed(3);
  Expect(!renderers.Check(3, {9, 7}), "order does not matter");
  // The iframe's renderer ended, or the iframe went.
  renderers.Changed(3);
  Expect(renderers.Check(3, {7}), "a renderer that left is reported");
  renderers.Changed(3);
  Expect(renderers.Check(3, {}), "a page with no renderer is reported");

  Expect(renderers.size() == 1, "browser 4's check has not run");
  renderers.Forget(4);
  Expect(!renderers.Pending(4), "a closed browser waits for nothing");
  renderers.Forget(3);
  Expect(renderers.size() == 0, "closed browsers are forgotten");
  Expect(renderers.Changed(3) && renderers.Check(3, {}), "a browser id seen again reports its first check");

  if (failures == 0) std::printf("frame_renderers_test: ok\n");
  return failures == 0 ? 0 : 1;
}
