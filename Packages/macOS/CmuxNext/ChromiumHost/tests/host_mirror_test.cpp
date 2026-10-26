// Checks the Chromium Host's mirror producers (ChromiumHost/src/host_mirror.h):
// which watched keys each refresh event names (tab, window, profile, one
// preference), the pref_get watch registration and the tab -> window map
// (scripts/cmux-next/tests/chromium-host-mirror.test.sh).
#include <cstdio>
#include <string>
#include <utility>
#include <vector>

#include "../src/host_mirror.h"
#include "cmux_cef_shim.h"

namespace control = cmux_host::control;
using cmux_host::HostMirror;
using cmux_host::MirrorEvent;
using cmux_host::MirrorKey;
using cmux_host::MirrorScope;

namespace {

int failures = 0;

void Check(bool ok, const char* what) {
  if (!ok) {
    ++failures;
    std::fprintf(stderr, "FAIL %s\n", what);
  }
}

// Op ids as the generated table would number them; only pref_get's matters.
constexpr uint16_t kOpSslStatus = 101;
constexpr uint16_t kOpSidePanelState = 102;
constexpr uint16_t kOpExtActions = 103;
constexpr uint16_t kOpExtList = 104;
constexpr uint16_t kOpOmniboxKeywords = 105;
constexpr uint16_t kOpPopupWindowBounds = 106;
constexpr uint16_t kOpForkApiVersion = 107;
constexpr uint16_t kOpPrefGet = 108;

MirrorKey Tab(int32_t browser) { return {control::Field::I32(1, browser)}; }
MirrorKey TabIcon(int32_t browser, int32_t icon_px) {
  return {control::Field::I32(1, browser), control::Field::I32(2, icon_px)};
}
MirrorKey Pref(const std::string& profile, const std::string& name) {
  return {control::Field::Str(1, profile), control::Field::Str(2, name)};
}

MirrorEvent Event(int kind, int32_t browser, int request = 0, int64_t a = 0, const char* s1 = nullptr,
                  const char* s2 = nullptr) {
  MirrorEvent event;
  event.kind = kind;
  event.browser = browser;
  event.request = request;
  event.a = a;
  event.s1 = s1;
  event.s2 = s2;
  return event;
}

MirrorEvent TabEvent(int request, int32_t browser, int64_t window) {
  return Event(CMUX_SHIM_TAB_EVENT, browser, request, window);
}

struct Watches {
  std::vector<std::pair<std::string, std::string>> calls;
  HostMirror::WatchPref fn() {
    return [this](const char* profile, const char* name) {
      calls.emplace_back(profile, name);
      return 1;
    };
  }
};

void TestTabScope() {
  Watches watches;
  HostMirror mirror(kOpPrefGet, watches.fn());
  MirrorEvent load_end = Event(CMUX_SHIM_LOAD_END, 7);
  Check(mirror.Refreshes(kOpSslStatus, load_end, Tab(7)), "LOAD_END refreshes the tab's ssl_status");
  Check(!mirror.Refreshes(kOpSslStatus, load_end, Tab(8)), "LOAD_END leaves another tab's ssl_status");
  Check(mirror.Refreshes(kOpExtActions, load_end, TabIcon(7, 32)), "LOAD_END refreshes the tab's ext_actions");
  Check(mirror.Refreshes(kOpForkApiVersion, load_end, {}), "a key with no arguments refreshes on any refresh");
  Check(!mirror.Refreshes(kOpSslStatus, Event(-1, 0), Tab(7)), "attach names no tab key");
  Check(mirror.Refreshes(kOpForkApiVersion, Event(-1, 0), {}), "attach refreshes host keys");
  Check(HostMirror::ScopeOf(TabEvent(cmux_host::kTabInserted, 7, 40)) == MirrorScope::kTab,
        "TAB_EVENT inserted is the tab's");
}

void TestWindowScope() {
  Watches watches;
  HostMirror mirror(kOpPrefGet, watches.fn());
  mirror.Track(Event(CMUX_SHIM_AFTER_CREATED, 1, 0, 40));
  mirror.Track(Event(CMUX_SHIM_AFTER_CREATED, 2, 0, 40));
  mirror.Track(Event(CMUX_SHIM_AFTER_CREATED, 3, 0, 41));
  // A popup Chromium places later: no window at AFTER_CREATED, then inserted.
  mirror.Track(Event(CMUX_SHIM_AFTER_CREATED, 4, 0, 0));
  Check(mirror.WindowOf(4) == 0, "an unplaced popup has no window");
  mirror.Track(TabEvent(cmux_host::kTabInserted, 4, 40));
  Check(mirror.WindowOf(4) == 40, "inserted places the popup");

  // The fork reports the change from the window's active tab (1).
  MirrorEvent panel = TabEvent(cmux_host::kTabSidePanelChanged, 1, 40);
  Check(mirror.Refreshes(kOpSidePanelState, panel, Tab(1)), "side panel change: the reporting tab");
  Check(mirror.Refreshes(kOpSidePanelState, panel, Tab(2)), "side panel change: another tab of the window");
  Check(mirror.Refreshes(kOpSidePanelState, panel, Tab(4)), "side panel change: the placed popup");
  Check(!mirror.Refreshes(kOpSidePanelState, panel, Tab(3)), "side panel change: not a tab of another window");
  MirrorEvent actions = TabEvent(cmux_host::kTabExtensionActionsChanged, 1, 40);
  Check(mirror.Refreshes(kOpExtActions, actions, TabIcon(2, 32)), "actions change: every tab of the window");
  Check(!mirror.Refreshes(kOpExtActions, actions, TabIcon(3, 32)), "actions change: not another window's");

  // Moved to window 41: now refreshed with that window, not the old one.
  mirror.Track(TabEvent(cmux_host::kTabRemoved, 2, 40));
  Check(mirror.WindowOf(2) == 0, "removed forgets the window");
  mirror.Track(TabEvent(cmux_host::kTabInserted, 2, 41));
  Check(!mirror.Refreshes(kOpSidePanelState, panel, Tab(2)), "a moved tab leaves its old window's refresh");
  Check(mirror.Refreshes(kOpSidePanelState, TabEvent(cmux_host::kTabSidePanelChanged, 3, 41), Tab(2)),
        "a moved tab joins its new window's refresh");
  mirror.Track(TabEvent(cmux_host::kTabMoved, 3, 40));
  Check(mirror.WindowOf(3) == 40, "moved names the new window");
  // A removed event of the old window after the tab moved on keeps the new one.
  mirror.Track(TabEvent(cmux_host::kTabRemoved, 3, 41));
  Check(mirror.WindowOf(3) == 40, "a stale removed keeps the current window");

  mirror.Track(Event(CMUX_SHIM_BEFORE_CLOSE, 1));
  Check(mirror.WindowOf(1) == 0, "BEFORE_CLOSE forgets the tab");
  mirror.Track(TabEvent(cmux_host::kTabWindowDestroyed, 0, 40));
  Check(mirror.WindowOf(3) == 0 && mirror.WindowOf(4) == 0, "window destroyed forgets its tabs");
  Check(mirror.WindowOf(2) == 41, "window destroyed keeps other windows' tabs");
  Check(!mirror.Refreshes(kOpSidePanelState, TabEvent(cmux_host::kTabSidePanelChanged, 9, 0), Tab(2)),
        "window 0 names no tab");
}

void TestWindowKeyAndProfileScope() {
  Watches watches;
  HostMirror mirror(kOpPrefGet, watches.fn());
  // popup_window.bounds[window_id]: keyed by the window, a = the window.
  MirrorEvent bounds = TabEvent(cmux_host::kTabPopupWindowBounds, 5, 77);
  Check(mirror.Refreshes(kOpPopupWindowBounds, bounds, Tab(77)), "popup bounds: the window's key");
  Check(!mirror.Refreshes(kOpPopupWindowBounds, bounds, Tab(5)), "popup bounds: not the browser's id");
  MirrorEvent extensions = TabEvent(cmux_host::kTabExtensionsChanged, 5, 40);
  Check(mirror.Refreshes(kOpExtList, extensions, Tab(5)), "extensions change: the reporting tab");
  Check(mirror.Refreshes(kOpExtList, extensions, Tab(99)), "extensions change: every tab");
  Check(mirror.Refreshes(kOpOmniboxKeywords, extensions, Tab(99)), "extensions change: every tab's keywords");
  Check(mirror.Refreshes(kOpExtActions, extensions, TabIcon(99, 32)), "extensions change: every tab's actions");
}

void TestPrefs() {
  Watches watches;
  HostMirror mirror(kOpPrefGet, watches.fn());
  const MirrorKey enable = Pref("/p/a", "credentials_enable_service");
  const MirrorKey other_profile = Pref("/p/b", "credentials_enable_service");
  const MirrorKey other_name = Pref("/p/a", "autofill.profile_enabled");

  // cmux watches the key: the host registers the shim watch before the first value.
  mirror.BeforeProduce(kOpPrefGet, enable, nullptr);
  Check(watches.calls.size() == 1 && watches.calls[0].first == "/p/a" &&
            watches.calls[0].second == "credentials_enable_service",
        "a watched pref key registers its shim watch");
  mirror.BeforeProduce(kOpSslStatus, Tab(7), nullptr);
  Check(watches.calls.size() == 1, "only pref_get registers a watch");

  MirrorEvent changed = Event(CMUX_SHIM_PREF_CHANGED, 0, 0, 0, "credentials_enable_service", "/p/a");
  Check(mirror.Refreshes(kOpPrefGet, changed, enable), "PREF_CHANGED refreshes the key it names");
  Check(!mirror.Refreshes(kOpPrefGet, changed, other_profile), "PREF_CHANGED leaves another profile");
  Check(!mirror.Refreshes(kOpPrefGet, changed, other_name), "PREF_CHANGED leaves another name");
  mirror.BeforeProduce(kOpPrefGet, enable, &changed);
  Check(watches.calls.size() == 1, "PREF_CHANGED's own refresh registers nothing");
  Check(!mirror.Refreshes(kOpPrefGet, Event(CMUX_SHIM_PREF_CHANGED, 0, 0, 0, nullptr, "/p/a"), enable),
        "a PREF_CHANGED without a name refreshes nothing");

  // A tab of a profile opens: the profile may be known only now.
  MirrorEvent created = Event(CMUX_SHIM_AFTER_CREATED, 12, 0, 40);
  Check(mirror.Refreshes(kOpPrefGet, created, other_profile), "AFTER_CREATED refreshes every pref key");
  mirror.BeforeProduce(kOpPrefGet, other_profile, &created);
  Check(watches.calls.size() == 2 && watches.calls[1].first == "/p/b", "AFTER_CREATED registers the watch again");
  Check(!mirror.Refreshes(kOpPrefGet, Event(CMUX_SHIM_LOAD_END, 12), enable), "a tab event leaves pref keys");

  const MirrorKey malformed = {control::Field::I32(1, 3), control::Field::Str(2, "x")};
  mirror.BeforeProduce(kOpPrefGet, malformed, nullptr);
  Check(watches.calls.size() == 2, "a malformed pref key registers nothing");

  HostMirror without_watch(kOpPrefGet, nullptr);
  without_watch.BeforeProduce(kOpPrefGet, enable, nullptr);  // no seam: nothing to call, no crash
}

}  // namespace

int main() {
  TestTabScope();
  TestWindowScope();
  TestWindowKeyAndProfileScope();
  TestPrefs();
  if (failures != 0) {
    std::fprintf(stderr, "host_mirror_test: %d failures\n", failures);
    return 1;
  }
  std::printf("host_mirror_test: ok\n");
  return 0;
}
