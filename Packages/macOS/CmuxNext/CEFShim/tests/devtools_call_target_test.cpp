// Checks CEFShim/src/devtools_call_target.h (scripts/cmux-next/test-shim-devtools-call-target-cpp.sh): a DevTools
// call that names a docked DevTools frontend's own id reaches that frontend. cmux's window image asks the frontend for
// its Page.captureScreenshot; the call found no browser (frontends are not page browsers), so the image striped the
// DevTools area as not captured (fleet capture, 2026-11-08).
#include <cstdio>
#include <map>
#include <memory>

#include "../src/devtools_call_target.h"

namespace {

struct FakeBrowser {
  int id;
  int GetIdentifier() const { return id; }
};
using Browser = std::shared_ptr<FakeBrowser>;

int failures = 0;

void Check(bool ok, const char* what) {
  if (!ok) {
    ++failures;
    std::fprintf(stderr, "FAIL %s\n", what);
  }
}

}  // namespace

int main() {
  // Page 7 has DevTools 41 open, page 9 has DevTools 52 open.
  std::map<int, Browser> open = {{7, std::make_shared<FakeBrowser>(FakeBrowser{41})},
                                 {9, std::make_shared<FakeBrowser>(FakeBrowser{52})}};
  Browser found = cmux_shim::DevToolsFrontendIn<Browser>(open, 41);
  Check(found && found->GetIdentifier() == 41, "a frontend's own id finds that frontend");
  found = cmux_shim::DevToolsFrontendIn<Browser>(open, 52);
  Check(found && found->GetIdentifier() == 52, "the second page's frontend");
  Check(!cmux_shim::DevToolsFrontendIn<Browser>(open, 7), "an inspected page's id is not a frontend");
  Check(!cmux_shim::DevToolsFrontendIn<Browser>(open, 99), "an id nothing has");
  std::map<int, Browser> none;
  Check(!cmux_shim::DevToolsFrontendIn<Browser>(none, 41), "no DevTools open");
  if (failures) return 1;
  std::printf("devtools_call_target: ok\n");
  return 0;
}
