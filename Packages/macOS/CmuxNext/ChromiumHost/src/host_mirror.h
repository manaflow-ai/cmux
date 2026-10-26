// The Chromium Host's producers of the navigation, window and count mirrors
// (plans/cmux-next/chrome-parity/p01-process.md 3.2, task p01-process-016):
// tab_navigation_entries, tab_navigation_state, tab_window_id, window_count,
// live_browser_count, foreign_browser_count and navigation_restore_supported.
// Each export's refresh_events in plans/cmux-next/chromium-host-ops.json say
// which events push it (kMirrorRefreshes in the generated host_dispatch.inc).
//
// The host pushes every open tab's keys before each event that changes them,
// with no watch from cmux: the remote shim's cache (remote_shim_mirror.h)
// holds tab_navigation_state's new entry in the same main-thread batch as
// the LOAD_START that made it. Chrome's browser process pushes session
// history the same way, from NavigationEntryCommitted to the session service
// (components/sessions/content/session_tab_helper.cc); nobody asks for it.
//
// Where the event carries the value, that value is pushed, as Chrome's
// TabStripModelChange carries the strip's state
// (chrome/browser/ui/tabs/tab_strip_model_observer.h): a tab's window at
// AFTER_CREATED and TAB_EVENT inserted or moved, the windows that remain at
// TAB_EVENT window destroyed (the fork counts that window until its
// destructor runs). A tab is open from its AFTER_CREATED to its BEFORE_CLOSE,
// whose keys go out with no value, so cmux's cache forgets them.
//
// UI thread only, like host_dispatch.mm: no lock.
#pragma once

#include <cstdint>
#include <unordered_set>

namespace cmux_host {

class HostContext;

// One shim event as the host forwards it; browser is cmux's id for the tab
// (the minted id once bound), 0 for an event about no tab.
struct MirrorEvent {
  int kind = 0;
  int request = 0;  // CMUX_SHIM_TAB_EVENT's sub-kind (cmux_tab_event_t)
  int32_t browser = 0;
  int64_t a = 0;
  int64_t b = 0;
};

class HostMirrors {
 public:
  // Before the event's refreshed mirrors are pushed.
  void EventArrived(const MirrorEvent& event);
  // Pushes `op` as `event` leaves it. False for a mirror these producers do
  // not own: the caller pushes its watched keys.
  bool Produce(HostContext& ctx, uint16_t op, const MirrorEvent& event) const;
  // After the event's refreshed mirrors are pushed.
  void EventSent(const MirrorEvent& event);

  size_t open_tabs() const { return open_tabs_.size(); }

 private:
  // cmux's ids of the tabs between AFTER_CREATED and BEFORE_CLOSE: bounded by
  // Chromium's live browsers.
  std::unordered_set<int32_t> open_tabs_;
};

}  // namespace cmux_host
