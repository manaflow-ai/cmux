// Checks the window request decision the shim makes with cmux's pushed policy
// (CEFShim/src/window_request_policy.h) on the cases
// CEFWindowPolicyTests checks for CEFWindowPolicy.decide in process. Run by
// scripts/cmux-next/test-window-request-policy-cpp.sh. No CEF.
#include <cstdio>
#include <cstdlib>
#include <map>
#include <string>

#include "../src/window_request_policy.h"

namespace {

using namespace cmux_shim;
using namespace cmux_shim::window_policy;

int failures = 0;
#define CHECK(cond)                                                                 \
  do {                                                                              \
    if (!(cond)) {                                                                  \
      std::fprintf(stderr, "%s:%d: CHECK failed: %s\n", __FILE__, __LINE__, #cond); \
      ++failures;                                                                   \
    }                                                                               \
  } while (0)

constexpr char kRoot[] = "/u/Library/cmux/Chromium";
const std::string kStoreA = std::string(kRoot) + "/Profile-A";
const std::string kStoreB = std::string(kRoot) + "/Profile-B";
constexpr char kIncognito[] = "otr-1";
constexpr int64_t kNow = 50'000;

// Chromium's window of each tab: tabs 1..3 in windows 101..103, the popup
// panel's tab 4 in 104, tab 5 in 101 with tab 1; tab 9 is in no window.
int WindowOf(int browser) {
  static const std::map<int, int> windows = {{1, 101}, {2, 102}, {3, 103}, {4, 104}, {5, 101}, {6, 106}};
  auto found = windows.find(browser);
  return found == windows.end() ? 0 : found->second;
}

WindowPolicyWindow Window(int anchor, int flags, const std::string& store, int opener = 0) {
  WindowPolicyWindow window;
  window.anchor = anchor;
  window.flags = flags;
  window.store = store;
  window.popup_opener = opener;
  return window;
}

// Panes: 1 (A, visible), 2 (A, last shown), 3 (B), the popup panel 4 (A,
// opened from pane 1), and 6 (an incognito window).
WindowPolicy Policy() {
  WindowPolicy policy;
  policy.windows = {Window(1, kCandidate | kVisible, kStoreA), Window(2, kCandidate | kLastShown, kStoreA),
                    Window(3, kCandidate, kStoreB), Window(4, 0, kStoreA, 1),
                    Window(6, kCandidate | kOffTheRecordStore, kIncognito)};
  policy.profile_root = kRoot;
  return policy;
}

WindowRequestFacts Request(int kind, int disposition, int source, bool gesture = true,
                           const std::string& profile = kStoreA) {
  WindowRequestFacts request;
  request.kind = kind;
  request.disposition = disposition;
  request.source = source;
  request.user_gesture = gesture;
  request.url = "https://example.com/next";
  request.profile_path = profile;
  return request;
}

WindowDecision Decide(const WindowPolicy& policy, const WindowRequestFacts& request) {
  return DecideWindowRequest(policy, request, kNow, WindowOf);
}

void IncognitoOpensNothingInChromium() {
  CHECK(Decide(Policy(), Request(kOffTheRecordKind, 3, 1)).outcome == kOffTheRecord);
  CHECK(Decide(Policy(), Request(kTabKind, 8, 1)).outcome == kOffTheRecord);  // OFF_THE_RECORD disposition
}

void TargetBlankGoesToTheSourcesWindow() {
  const WindowDecision decision = Decide(Policy(), Request(kTabKind, 3, 1));
  CHECK(decision.outcome == kInsert && decision.anchor == 1 && decision.new_tab == kForeground);
  CHECK(decision.store == kStoreA);
  // Any tab of the pane names its window: tab 5 shares window 101 with anchor 1.
  CHECK(Decide(Policy(), Request(kTabKind, 3, 5)).anchor == 1);
}

void ModifiedClicksFollowTheMapping() {
  WindowPolicy policy = Policy();
  policy.actions[0] = kLinkPlacementAction;  // cmux's Cmd-click
  CHECK(Decide(policy, Request(kTabKind, 4, 1)).new_tab == kLinkPlacement);
  // A script's request follows Chrome's mapping.
  CHECK(Decide(policy, Request(kTabKind, 4, 1, false)).new_tab == kBackground);
  // Shift-Cmd-click is told from target=_blank by the last click, at most 1 s old.
  policy.actions[1] = kNewWindowAction;
  policy.clicks[1] = WindowPolicyClick{kCmdShift, kNow - 400};
  CHECK(Decide(policy, Request(kTabKind, 3, 1)).new_tab == kNewWindow);
  policy.clicks[1] = WindowPolicyClick{kCmdShift, kNow - 1'500};
  CHECK(Decide(policy, Request(kTabKind, 3, 1)).new_tab == kForeground);
  policy.clicks[1] = WindowPolicyClick{kCmdShift, kNow + 10};  // from the future: no click
  CHECK(Decide(policy, Request(kTabKind, 3, 1)).new_tab == kForeground);
}

void CurrentTabAndDownloadStayInTheSource() {
  WindowPolicy policy = Policy();
  policy.actions[2] = kCurrentTab;  // Shift-click
  CHECK(Decide(policy, Request(kWindowKind, 6, 1)).outcome == kLoadInSource);
  CHECK(Decide(Policy(), Request(kTabKind, 7, 1)).outcome == kDownloadInSource);  // Option-click
  // Without a source (or a URL) there is nothing to load in: a selected tab.
  const WindowDecision sourceless = Decide(policy, Request(kTabKind, 7, 0));
  CHECK(sourceless.outcome == kInsert && sourceless.new_tab == kForeground && sourceless.anchor == 2);
  WindowRequestFacts urlless = Request(kTabKind, 7, 1);
  urlless.url.clear();
  CHECK(Decide(policy, urlless).outcome == kInsert);
}

void WindowsAndPopups() {
  // A window request that is no link click (chrome.windows.create) is a selected tab.
  CHECK(Decide(Policy(), Request(kWindowKind, 6, 0)).new_tab == kForeground);
  const WindowDecision popup = Decide(Policy(), Request(kPopupKind, 5, 1));
  CHECK(popup.outcome == kInsert && popup.new_tab == kPopup && popup.anchor == 1);
  // What a popup panel opens goes to the window of the pane that opened it.
  CHECK(Decide(Policy(), Request(kTabKind, 3, 4)).anchor == 1);
  // An unknown kind is a window.
  CHECK(Decide(Policy(), Request(42, 6, 0)).new_tab == kForeground);
}

void WithoutTheSourceThePreferenceOrderDecides() {
  CHECK(Decide(Policy(), Request(kWindowKind, 6, 0)).anchor == 2);  // last shown
  WindowPolicy policy = Policy();
  policy.windows[1].flags = kCandidate;
  CHECK(Decide(policy, Request(kWindowKind, 6, 0)).anchor == 1);  // visible
  policy.windows[0].flags = kCandidate;
  CHECK(Decide(policy, Request(kWindowKind, 6, 0)).anchor == 1);  // first by anchor
  // The other store's window takes only its own requests.
  CHECK(Decide(Policy(), Request(kWindowKind, 6, 0, true, kStoreB)).anchor == 3);
}

void AStoreWithNoWindow() {
  const std::string other = std::string(kRoot) + "/Profile-C";
  const WindowDecision persistent = Decide(Policy(), Request(kWindowKind, 6, 0, true, other));
  CHECK(persistent.outcome == kOpenInNewTab && persistent.store == other);
  // A directory cmux does not own (an off-the-record profile's parent) never becomes a normal tab.
  CHECK(Decide(Policy(), Request(kWindowKind, 6, 0, true, "/elsewhere/Profile-C")).outcome == kRefuseNoWindow);
  // An incognito pane's request with its window gone (not a candidate) is refused.
  WindowPolicy policy = Policy();
  policy.windows[4].flags = kOffTheRecordStore;
  const WindowDecision incognito = Decide(policy, Request(kTabKind, 3, 6, true, kStoreA));
  CHECK(incognito.outcome == kRefuseNoWindow && incognito.store == kIncognito);
  // With the window there, its own window.
  CHECK(Decide(Policy(), Request(kTabKind, 3, 6, true, kStoreA)).anchor == 6);
}

void AnAnchorWithNoChromiumWindowTakesNoTab() {
  WindowPolicy policy;
  policy.windows = {Window(9, kCandidate | kLastShown, kStoreA)};
  policy.profile_root = kRoot;
  CHECK(Decide(policy, Request(kWindowKind, 6, 0)).outcome == kOpenInNewTab);
}

void PersistentStores() {
  CHECK(IsPersistentStore(kStoreA, kRoot));
  CHECK(!IsPersistentStore(std::string(kRoot) + "/Other", kRoot));
  CHECK(!IsPersistentStore(std::string(kRoot) + "/x/Profile-A", kRoot));
  CHECK(!IsPersistentStore("Profile-A", kRoot));
  CHECK(!IsPersistentStore(kStoreA, ""));
}

}  // namespace

int main() {
  IncognitoOpensNothingInChromium();
  TargetBlankGoesToTheSourcesWindow();
  ModifiedClicksFollowTheMapping();
  CurrentTabAndDownloadStayInTheSource();
  WindowsAndPopups();
  WithoutTheSourceThePreferenceOrderDecides();
  AStoreWithNoWindow();
  AnAnchorWithNoChromiumWindowTakesNoTab();
  PersistentStores();
  if (failures != 0) {
    std::fprintf(stderr, "window_request_policy_test: %d failure(s)\n", failures);
    return EXIT_FAILURE;
  }
  std::puts("window_request_policy_test: ok");
  return EXIT_SUCCESS;
}
