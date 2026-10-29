// The Chromium Host's producers of the tab and host mirrors
// (plans/cmux-next/chrome-parity/p01-process.md 3.2
// and 017): tab_navigation_entries, tab_navigation_state, tab_window_id,
// window_count, live_browser_count and foreign_browser_count (016);
// side_panel_state, ext_actions, ext_list, ext_commands and omnibox_keywords
// (017); renderer_client_ids (225: the tab's frames' renderers, which cmux
// maps to the host's helper pids). Each export's refresh_events in plans/cmux-next/chromium-host-ops.json
// say which events push it (kMirrorRefreshes in the generated host_dispatch.inc).
// navigation_restore_supported is a fork capability: host_dispatch.mm pushes
// it once, before the hello (ProduceAttach).
//
// The host pushes every open tab's keys before each event that changes them,
// with no watch from cmux: the remote shim's cache (remote_shim_mirror.h)
// holds tab_navigation_state's new entry in the same main-thread batch as
// the LOAD_START that made it. The history (with page state) and the
// Back/Forward entries are read only at the events that change the
// committed history: AFTER_CREATED, ADDRESS (a commit, same-document ones
// too) and LOAD_START, never at TITLE, LOAD_END or LOADING_STATE. Chrome's
// SessionTabHelper does the same: it records a tab's history at
// NavigationEntryCommitted (components/sessions/content/session_tab_helper.cc),
// and page state after the load is task 093's (at idle or hide). A value over
// the frame bound goes out as a forget (HostContext::PushMirror), so the cache
// never keeps an older history.
//
// Which tabs a refresh names depends on the mirror and the event, as Chrome
// scopes each observer to its owner: most refreshes name the event's tab
// (WebContentsObserver); the side panel's and the toolbar actions' change in
// a window names every tab of that Chromium window (SidePanelCoordinator and
// ExtensionsToolbarContainer belong to a Browser,
// chrome/browser/ui/views/side_panel/side_panel_coordinator.h); an extension
// install, removal, enable or disable names every tab of the event's profile
// (ExtensionRegistryObserver is per BrowserContext,
// extensions/browser/extension_registry_observer.h). The host keeps each open
// tab's window and profile for that: a window has one profile, as a Browser
// has one Profile (chrome/browser/ui/browser.h).
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
#include <map>
#include <optional>
#include <set>
#include <string>
#include <vector>

#include "chromium_host_control.h"

namespace cmux_host {

class HostContext;

// CEFExtensionAction.iconPixels (OmnibarStyle.buttonSize * 2), the icon_px
// of every ext_actions read in cmux; chromium-host-dispatch.test.sh checks
// the Swift value.
inline constexpr int32_t kExtActionIconPixels = 56;

// One shim event as the host forwards it; browser is cmux's id for the tab
// (the minted id once bound), 0 for an event about no tab.
struct MirrorEvent {
  int kind = 0;
  int request = 0;  // CMUX_SHIM_TAB_EVENT's sub-kind (cmux_tab_event_t)
  int32_t browser = 0;
  int64_t a = 0;
  int64_t b = 0;
  // AFTER_CREATED of a create_window: its profile_cache_path ("" the default
  // profile). Unset for a tab Chromium made: it takes its window's profile.
  std::optional<std::string> profile;
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
  // HostContext::RefreshMirror for a mirror these producers own: pushes each
  // open tab's key (or the host's) that `named` and `wildcards` match. False
  // for a mirror they do not own.
  bool Refresh(HostContext& ctx, uint16_t op, const std::vector<control::Field>& named, uint32_t wildcards) const;

  // Whether `key` (every parameter) matches a pending key pattern: `named`
  // holds, in order, the parameters whose bit in `wildcards` is clear.
  static bool KeyMatches(const std::vector<control::Field>& key, const std::vector<control::Field>& named,
                         uint32_t wildcards);

  // A watched key of a mirror these producers do not own (the caller's
  // watched_): true when `event` names it. Its first field is a tab, or a
  // Chromium window for popup_window_bounds, which TAB_EVENT 6, 10 and 11
  // name in a.
  static bool Names(uint16_t op, const MirrorEvent& event, const std::vector<control::Field>& key);
  // True when the watched `key` of `op` belongs to tab `browser` (forgotten when it closes).
  static bool NamesTab(uint16_t op, const std::vector<control::Field>& key, int32_t browser);

  size_t open_tabs() const { return tabs_.size(); }
  // The tab's Chromium window, 0 when unknown or not open.
  int64_t WindowOf(int32_t browser) const;
  // Whether an open tab is in Chromium window `window`.
  bool HasTabs(int64_t window) const { return tabs_of_window_.count(window) > 0; }
  // The tab's profile cache path, nullopt when unknown or not open.
  std::optional<std::string> ProfileOf(int32_t browser) const;

 private:
  struct Tab {
    int64_t window = 0;
    std::optional<std::string> profile;
  };

  // The open tabs `op`'s refresh at `event` names, in id order.
  std::vector<int32_t> TabsFor(uint16_t op, const MirrorEvent& event) const;
  void Place(int32_t browser, int64_t window);
  void SetProfile(int32_t browser, const std::string& profile);
  void Unplace(int32_t browser);
  void Close(int32_t browser);
  void WindowDestroyed(int64_t window);

  // cmux's ids of the tabs between AFTER_CREATED and BEFORE_CLOSE, and the
  // two indexes over them: all bounded by Chromium's live browsers and
  // windows, so a window or profile refresh costs the tabs it names.
  std::map<int32_t, Tab> tabs_;
  std::map<int64_t, std::set<int32_t>> tabs_of_window_;
  std::map<std::string, std::set<int32_t>> tabs_of_profile_;
  std::map<int64_t, std::string> profile_of_window_;
};

}  // namespace cmux_host
