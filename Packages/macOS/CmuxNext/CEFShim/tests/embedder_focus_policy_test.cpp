// Checks the Chromium Host's focus rule (CEFShim/src/embedder_focus_policy.h,
// no CEF needed; scripts/cmux-next/test-shim-embedder-focus-cpp.sh): only the
// page cmux marked embedder-active may take focus (task p01-process-032).
#include <cstdio>

#include "../src/embedder_focus_policy.h"

using cmux_shim::EmbedderFocusPolicy;

static int failures = 0;
static int cases = 0;

static void Check(bool ok, const char* what) {
  ++cases;
  if (!ok) {
    ++failures;
    std::fprintf(stderr, "FAIL %s\n", what);
  }
}

// Before cmux marks any page, no page takes focus: a new browser's first
// load (CEF's navigation focus) cannot take the keys.
static void NothingActiveRefusesEveryPage() {
  EmbedderFocusPolicy policy;
  Check(!policy.Allows(1), "an unmarked page is refused");
  Check(!policy.Allows(0), "browser 0 is refused");
  Check(!policy.Allows(-1), "a negative id is refused");
}

// Two panes: cmux's first responder shows page 1. Page 2's navigation in the
// background pane asks for focus and is refused; page 1's own load after it
// was focused keeps the focus.
static void BackgroundNavigationIsRefusedFocusedLoadIsGranted() {
  EmbedderFocusPolicy policy;
  policy.SetActive(1, true);
  Check(policy.Allows(1), "the focused pane's page gets focus after its load");
  Check(!policy.Allows(2), "a background pane's navigation takes no focus");
}

// cmux's focus moves from page 1 to page 2. The new page's mark can come
// before the old one's blur: the late blur of page 1 must not clear page 2.
static void FocusMovesAndALateBlurKeepsTheNewPage() {
  EmbedderFocusPolicy policy;
  policy.SetActive(1, true);
  policy.SetActive(2, true);
  Check(policy.Allows(2) && !policy.Allows(1), "one active page: the last marked");
  policy.SetActive(1, false);
  Check(policy.Allows(2), "the old page's late blur leaves the new page active");
  policy.SetActive(2, false);
  Check(!policy.Allows(2) && policy.active() == 0, "the blur of the active page leaves none");
}

// The active page closes: it is forgotten; another page's close changes nothing.
static void ClosingTheActivePageForgetsIt() {
  EmbedderFocusPolicy policy;
  policy.SetActive(5, true);
  policy.Forget(4);
  Check(policy.Allows(5), "another page's close changes nothing");
  policy.Forget(5);
  Check(!policy.Allows(5) && policy.active() == 0, "the closed active page is forgotten");
}

// A mark for an id that is no browser grants nothing.
static void InvalidIdsGrantNothing() {
  EmbedderFocusPolicy policy;
  policy.SetActive(3, true);
  policy.SetActive(0, true);
  Check(policy.active() == 0 && !policy.Allows(3), "marking id 0 active clears the old page, grants none");
  policy.SetActive(-2, true);
  Check(!policy.Allows(-2), "a negative id is never granted");
}

int main() {
  NothingActiveRefusesEveryPage();
  BackgroundNavigationIsRefusedFocusedLoadIsGranted();
  FocusMovesAndALateBlurKeepsTheNewPage();
  ClosingTheActivePageForgetsIt();
  InvalidIdsGrantNothing();
  if (failures) {
    std::fprintf(stderr, "embedder focus policy: %d of %d checks failed\n", failures, cases);
    return 1;
  }
  std::printf("embedder focus policy: %d checks passed\n", cases);
  return 0;
}
