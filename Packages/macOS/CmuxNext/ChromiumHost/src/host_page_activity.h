// The Chromium Host's App Nap (plans/cmux-next/chrome-parity/p14-energy.md,
// task 128; p01-process.md, task 222). The host's page windows are never
// ordered in (HostPageViews), and it is an accessory app, so to macOS it is a
// background app with nothing on screen, and App Nap may throttle it while it
// draws a page cmux shows. Chrome's renderer holds an activity only while it
// is foregrounded and lets App Nap apply when it is backgrounded
// (content/common/mac/app_nap_activity.mm, AppNapActivity::Begin and End:
// NSActivityUserInitiatedAllowingIdleSystemSleep). The host holds one at one
// of two levels:
//   kActive  cmux is the active app: the person types and scrolls into it, so
//            the host also asks for latency-critical timers and I/O
//            (NSActivityLatencyCritical), as Chrome's browser process gets as
//            the foreground app;
//   kShown   cmux shows one page or more (CMUX_SHIM_PAGE_VISIBLE, the value
//            cmux posts per page with cmux_shim_browser_set_page_visibility)
//            while another app is active: Chrome's AppNapActivity alone.
// It holds none when cmux is hidden or shows no page while another app is
// active, so that host naps.
//
// cmux's active and hidden state comes from macOS (browser_host_main.mm,
// ParentAppObserver: NSWorkspace's activate and hide notifications for the
// parent pid), the one record of it.
//
// The fork applies a post to the posted browser's Chromium window, every tab
// of it, and cmux posts for one tab of each pane's window (its first). So
// what shows is a window, not a browser: PageWindowVisibility keeps cmux's
// last value per Chromium window, as the fork does, and counts the shown
// windows. Closing or moving out the tab a post named leaves the value with
// the window's other tabs; the value goes with the window's last tab.
// HostContext feeds it the posts and the tab events that place tabs in
// windows (HostMirrors), and hands the count here on each change.
//
// The activity is held at kShown or above from the host's start until the
// first count after initialize (HostContext::Resume): cmux starts a host for
// a page it is about to show, and Chromium's start should not run napped.
//
// Plain C++, no AppKit: browser_host_main.mm passes the NSProcessInfo calls,
// and the tests a recorder (scripts/cmux-next/tests/chromium-host-dispatch.test.sh).
// Main thread only, like HostContext.
#pragma once

#include <cstddef>
#include <cstdint>
#include <functional>
#include <string>
#include <unordered_map>
#include <utility>

#include "cmux_cef_shim.h"

namespace cmux_host {

// How much the host keeps App Nap off (see the top of this file).
enum class ActivityLevel : uint8_t { kNone, kShown, kActive };

// What the host's activity follows, and the level it comes to.
struct ActivityState {
  ActivityLevel level = ActivityLevel::kNone;
  bool starting = true;
  bool app_active = false;
  bool app_hidden = false;
  size_t shown_pages = 0;
};

inline const char* ActivityLevelName(ActivityLevel level) {
  switch (level) {
    case ActivityLevel::kNone: return "none";
    case ActivityLevel::kShown: return "shown";
    case ActivityLevel::kActive: return "active";
  }
  return "none";
}

// The host log's line for a change of level (cmux's stderr).
inline std::string ActivityLogLine(const ActivityState& state) {
  return std::string("cmux-chromium-host: app nap activity ") + ActivityLevelName(state.level) +
         " (cmux active " + (state.app_active ? "1" : "0") + ", hidden " + (state.app_hidden ? "1" : "0") +
         ", shown pages " + std::to_string(state.shown_pages) + (state.starting ? ", starting" : "") + ")\n";
}

class PageShowActivity {
 public:
  // Holds the activity at `state.level` (kNone: ends it); called only on a
  // change of level.
  using Hold = std::function<void(const ActivityState& state)>;

  // Begins the activity: the host starts held.
  explicit PageShowActivity(Hold hold) : hold_(std::move(hold)) { Update(); }
  PageShowActivity(const PageShowActivity&) = delete;
  PageShowActivity& operator=(const PageShowActivity&) = delete;

  // `shown` pages are on screen. The first count ends the start's hold.
  void SetShownPages(size_t shown) {
    state_.starting = false;
    state_.shown_pages = shown;
    Update();
  }
  // cmux (the parent app) is `active`, `hidden`.
  void SetApp(bool active, bool hidden) {
    state_.app_active = active;
    state_.app_hidden = hidden;
    Update();
  }

  bool held() const { return state_.level != ActivityLevel::kNone; }
  ActivityLevel level() const { return state_.level; }
  const ActivityState& state() const { return state_; }
  // Changes of level so far, the start's begin included.
  uint64_t edges() const { return edges_; }

 private:
  static ActivityLevel LevelOf(const ActivityState& state) {
    if (state.app_active) return ActivityLevel::kActive;
    if (state.starting || (!state.app_hidden && state.shown_pages > 0)) return ActivityLevel::kShown;
    return ActivityLevel::kNone;
  }

  void Update() {
    const ActivityLevel level = LevelOf(state_);
    if (edges_ > 0 && level == state_.level) return;
    state_.level = level;
    ++edges_;
    if (hold_) hold_(state_);
  }

  Hold hold_;
  ActivityState state_;
  uint64_t edges_ = 0;
};

// cmux's page visibility (cmux_shim_page_visibility_t) per Chromium window,
// and how many windows are CMUX_SHIM_PAGE_VISIBLE. A post for a browser whose
// window the host does not know (none in its AFTER_CREATED yet) is kept for
// that browser alone until it is placed in a window or closes. HostContext
// ends a window's entry when the window has no tab left and a browser's at its
// close, so both maps hold live objects only.
class PageWindowVisibility {
 public:
  // cmux's `visibility` for `browser`, a tab of Chromium window `window` (0:
  // none known).
  void Post(int64_t window, int32_t browser, int32_t visibility) {
    if (window == 0) return Set(unplaced_, browser, visibility);
    Drop(unplaced_, browser);
    Set(windows_, window, visibility);
  }
  // `browser` is now a tab of `window` (not 0): a value kept for it alone
  // becomes the window's when the window has none.
  void Placed(int32_t browser, int64_t window) {
    auto alone = unplaced_.find(browser);
    if (alone == unplaced_.end()) return;
    const int32_t visibility = alone->second;
    Drop(unplaced_, browser);
    if (!windows_.count(window)) Set(windows_, window, visibility);
  }
  // `window` has no tab left (its last one closed or moved out): its value goes.
  void WindowGone(int64_t window) { Drop(windows_, window); }
  // `browser` closed: a value kept for it alone goes.
  void BrowserClosed(int32_t browser) { Drop(unplaced_, browser); }

  // The windows, and browsers with no window, that cmux shows.
  size_t shown() const { return shown_; }
  bool empty() const { return windows_.empty() && unplaced_.empty(); }

 private:
  static bool Shown(int32_t visibility) { return visibility == CMUX_SHIM_PAGE_VISIBLE; }

  template <typename Map>
  void Set(Map& map, typename Map::key_type key, int32_t visibility) {
    auto [entry, added] = map.try_emplace(key, visibility);
    if (!added) {
      if (Shown(entry->second)) --shown_;
      entry->second = visibility;
    }
    if (Shown(visibility)) ++shown_;
  }
  template <typename Map>
  void Drop(Map& map, typename Map::key_type key) {
    auto found = map.find(key);
    if (found == map.end()) return;
    if (Shown(found->second)) --shown_;
    map.erase(found);
  }

  std::unordered_map<int64_t, int32_t> windows_;
  std::unordered_map<int32_t, int32_t> unplaced_;
  size_t shown_ = 0;
};

}  // namespace cmux_host
