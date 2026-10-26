// Which watched mirror keys an event refreshes in the Chromium Host
// (plans/cmux-next/chrome-parity/p01-process.md 3.2, tasks p01-process-016
// and 017). The generated ProduceMirror reads one key from the shim;
// HostMirror picks the keys: those of the event's tab, of every tab in the
// event's Chromium window, of the whole profile, or the one preference the
// event names. Chrome scopes its observers the same way: WebContentsObserver
// per tab, a Browser's TabStripModelObserver per window,
// ExtensionRegistryObserver per profile and PrefChangeRegistrar per
// preference (components/prefs/pref_change_registrar.cc).
//
// The dispatcher (host_dispatch.mm, task 013) asks Refreshes for each key it
// watches before it pushes the event, then calls Track. Runs on the host's UI
// thread only; no lock.
#pragma once

#include <cstdint>
#include <functional>
#include <unordered_map>
#include <vector>

#include "chromium_host_control.h"

namespace cmux_host {

// cmux_tab_event_t of the fork (include/cef_cmux.h; CEFForkTabEvent in
// CEFShimEvent.swift): CMUX_SHIM_TAB_EVENT's request. a = window id.
enum TabEventKind : int {
  kTabInserted = 0,
  kTabMoved = 2,
  kTabRemoved = 3,
  kTabExtensionActionsChanged = 4,
  kTabWindowDestroyed = 6,
  kTabExtensionsChanged = 7,
  kTabPopupWindowCreated = 10,
  kTabPopupWindowBounds = 11,
  kTabSidePanelChanged = 12,
};

// One shim event with cmux's ids (the browser is the client id).
struct MirrorEvent {
  int kind = 0;  // cmux_shim_event_kind_t, or a pseudo event (< 0: attach)
  int32_t browser = 0;
  int request = 0;
  int64_t a = 0;
  int64_t b = 0;
  const char* s1 = nullptr;
  const char* s2 = nullptr;
};

// A mirror key: the export's arguments as the watch carried them.
using MirrorKey = std::vector<control::Field>;

// The keys an event names.
enum class MirrorScope : uint8_t {
  kNone,       // a pseudo event: only keys with no arguments
  kTab,        // key[0] is the event's tab
  kWindow,     // key[0] is a tab in the event's window (a), or the event's tab
  kWindowKey,  // key[0] is the event's window id (popup_window.bounds)
  kProfile,    // every key: a profile-wide change reported from one of its tabs
};

class HostMirror {
 public:
  // Registers CMUX_SHIM_PREF_CHANGED for one preference
  // (cmux_shim_pref_watch(profile_cache_path, pref_name, 1) in the host).
  using WatchPref = std::function<int(const char* profile_cache_path, const char* pref_name)>;

  // pref_get_op: the generated id of cmux_shim_pref_get (kOpPrefGet).
  HostMirror(uint16_t pref_get_op, WatchPref watch_pref);
  HostMirror(const HostMirror&) = delete;
  HostMirror& operator=(const HostMirror&) = delete;

  // The scope of an event for every mirror but pref_get.
  static MirrorScope ScopeOf(const MirrorEvent& event);

  // True when `event` refreshes the watched `key` of mirror `op`. A key
  // with no arguments is refreshed by every refresh event of its mirror.
  bool Refreshes(uint16_t op, const MirrorEvent& event, const MirrorKey& key) const;

  // Before ProduceMirror reads `key`: a pref_get key gets its preference
  // watch, at the watch from cmux (cause null) and at each refresh other
  // than its own PREF_CHANGED. The shim drops watches with the profile
  // (cmux_shim_release_context) and refuses one for a profile not known
  // yet, so AFTER_CREATED registers it again; a repeat costs nothing.
  void BeforeProduce(uint16_t op, const MirrorKey& key, const MirrorEvent* cause);

  // After the event's refresh: keeps the tab -> window map that kWindow uses.
  void Track(const MirrorEvent& event);

  // The Chromium window of a tab, 0 when unknown.
  int64_t WindowOf(int32_t browser) const;

 private:
  bool IsTab(const MirrorKey& key, int64_t id) const;
  bool NamesPref(const MirrorKey& key, const MirrorEvent& event) const;

  const uint16_t pref_get_op_;
  const WatchPref watch_pref_;
  // Bounded by the host's live browsers: BEFORE_CLOSE and window destruction erase.
  std::unordered_map<int32_t, int64_t> window_of_;
};

}  // namespace cmux_host
