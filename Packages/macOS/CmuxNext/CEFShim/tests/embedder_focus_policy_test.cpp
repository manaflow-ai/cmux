// Checks the Chromium Host's focus rule (CEFShim/src/embedder_focus_policy.h,
// no CEF needed; scripts/cmux-next/test-shim-embedder-focus-cpp.sh): only a
// page cmux marked embedder-active may take focus.
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

// cmux's focus moves from page 1 to page 2 in one window. The new page's mark
// can come before the old one's blur; either order leaves page 2 alone.
static void FocusMovesInAWindowInEitherOrder() {
  EmbedderFocusPolicy policy;
  policy.SetActive(1, true);
  policy.SetActive(2, true);
  policy.SetActive(1, false);
  Check(policy.Allows(2) && !policy.Allows(1), "mark then blur: the new page alone");
  policy.SetActive(2, false);
  policy.SetActive(1, true);
  Check(policy.Allows(1) && !policy.Allows(2), "blur then mark: the new page alone");
  policy.SetActive(1, false);
  Check(policy.active_count() == 0, "the blur of the last marked page leaves none");
}

// cmux has one first responder per window. Window 1 shows page A, window 2
// page B; neither window blurs its page when the other becomes key, and
// returning to window 1 posts nothing again (its page view kept the
// responder, CEFTab's cache skips a repeat). Both stay marked, so A's own
// load in the key window is granted, and a blur of one keeps the other.
static void PagesInTwoWindowsStayMarked() {
  const int a = 7, b = 8, background = 9;
  EmbedderFocusPolicy policy;
  policy.SetActive(a, true);  // window 1 focuses page A
  policy.SetActive(b, true);  // window 2 becomes key, focuses page B
  // Back in window 1: no post. A link click in A navigates and asks for focus.
  Check(policy.Allows(a), "the key window's page gets focus after its load");
  Check(policy.Allows(b), "the other window's page keeps its own mark");
  Check(!policy.Allows(background), "a background pane in either window is refused");
  policy.SetActive(b, false);  // window 2's pane moves its focus to a terminal
  Check(policy.Allows(a) && !policy.Allows(b), "a blur in one window keeps the other window's page");
}

// The active page closes: it is forgotten; another page's close changes nothing.
static void ClosingTheActivePageForgetsIt() {
  EmbedderFocusPolicy policy;
  policy.SetActive(5, true);
  policy.Forget(4);
  Check(policy.Allows(5), "another page's close changes nothing");
  policy.Forget(5);
  Check(!policy.Allows(5) && policy.active_count() == 0, "the closed active page is forgotten");
}

// A mark for an id that is no browser grants nothing and changes nothing.
static void InvalidIdsGrantNothing() {
  EmbedderFocusPolicy policy;
  policy.SetActive(3, true);
  policy.SetActive(0, true);
  policy.SetActive(-2, true);
  Check(policy.Allows(3) && policy.active_count() == 1, "marking id 0 or a negative id changes nothing");
  Check(!policy.Allows(0) && !policy.Allows(-2), "id 0 and a negative id are never granted");
}

// CefFocusHandler::OnSetFocus's answer (Client::OnSetFocus -> RefusesFocus in
// shim_browser.mm calls Refuses with the Host's handler). In host mode no
// handler is installed and the mark decides; in process cmux's handler
// decides, whatever the marks.
static int handler_calls = 0;
static int HandlerGrantsBrowser4(void* ctx, int browser_id, int) {
  ++handler_calls;
  return ctx == &handler_calls && browser_id == 4 ? 1 : 0;
}

static void OnSetFocusFollowsTheMarkWithNoHandler() {
  EmbedderFocusPolicy policy;
  const int navigation = 0, system = 1;
  Check(policy.Refuses(nullptr, nullptr, 3, navigation), "host mode: an unmarked page's navigation is cancelled");
  policy.SetActive(3, true);
  Check(!policy.Refuses(nullptr, nullptr, 3, navigation), "host mode: the marked page's navigation focus goes on");
  Check(!policy.Refuses(nullptr, nullptr, 3, system), "host mode: the marked page's own SetFocus goes on");
  Check(policy.Refuses(nullptr, nullptr, 4, navigation), "host mode: a background page's navigation is cancelled");
  Check(handler_calls == 0, "host mode: no handler is asked");
}

static void OnSetFocusAsksAnInstalledHandler() {
  EmbedderFocusPolicy policy;
  policy.SetActive(3, true);
  Check(policy.Refuses(&HandlerGrantsBrowser4, &handler_calls, 3, 0), "in process: the handler refuses a marked page");
  Check(!policy.Refuses(&HandlerGrantsBrowser4, &handler_calls, 4, 0), "in process: the handler grants an unmarked page");
  Check(handler_calls == 2, "in process: the handler decides every request");
}

int main() {
  NothingActiveRefusesEveryPage();
  BackgroundNavigationIsRefusedFocusedLoadIsGranted();
  FocusMovesInAWindowInEitherOrder();
  PagesInTwoWindowsStayMarked();
  ClosingTheActivePageForgetsIt();
  InvalidIdsGrantNothing();
  OnSetFocusFollowsTheMarkWithNoHandler();
  OnSetFocusAsksAnInstalledHandler();
  if (failures) {
    std::fprintf(stderr, "embedder focus policy: %d of %d checks failed\n", failures, cases);
    return 1;
  }
  std::printf("embedder focus policy: %d checks passed\n", cases);
  return 0;
}
