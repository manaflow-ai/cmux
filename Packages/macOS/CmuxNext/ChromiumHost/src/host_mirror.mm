// The Chromium Host's mirror producers (host_mirror.h): which watched keys
// each refresh event names, the pref_get watches, and the tab -> window map.
// The refresh events themselves are plans/cmux-next/chromium-host-ops.json's
// (kMirrorRefreshes in the generated host_dispatch.inc). No AppKit: this file
// is C++ and its test builds it on any host.

#include "host_mirror.h"

#include <iterator>
#include <utility>

#include "cmux_cef_shim.h"

namespace cmux_host {

HostMirror::HostMirror(uint16_t pref_get_op, WatchPref watch_pref)
    : pref_get_op_(pref_get_op), watch_pref_(std::move(watch_pref)) {}

MirrorScope HostMirror::ScopeOf(const MirrorEvent& event) {
  if (event.kind < 0) return MirrorScope::kNone;
  if (event.kind != CMUX_SHIM_TAB_EVENT) return MirrorScope::kTab;
  switch (event.request) {
    // Toolbar actions and the side panel are per window; the event's tab is
    // the window's active one (CEFRuntime+Events refreshes every tab of the window).
    case kTabExtensionActionsChanged:
    case kTabSidePanelChanged:
      return MirrorScope::kWindow;
    // Install, removal, enable or disable changes every tab of the profile.
    case kTabExtensionsChanged:
      return MirrorScope::kProfile;
    case kTabWindowDestroyed:
    case kTabPopupWindowCreated:
    case kTabPopupWindowBounds:
      return MirrorScope::kWindowKey;
    default:
      return MirrorScope::kTab;
  }
}

bool HostMirror::IsTab(const MirrorKey& key, int64_t id) const {
  return !key.empty() && key[0].type == control::Type::kI32 && key[0].integer == id;
}

bool HostMirror::NamesPref(const MirrorKey& key, const MirrorEvent& event) const {
  // PREF_CHANGED: s1 = the preference name, s2 = the profile cache path.
  if (key.size() != 2 || event.s1 == nullptr || event.s2 == nullptr) return false;
  if (key[0].type != control::Type::kStr || key[1].type != control::Type::kStr) return false;
  return key[0].bytes == event.s2 && key[1].bytes == event.s1;
}

bool HostMirror::Refreshes(uint16_t op, const MirrorEvent& event, const MirrorKey& key) const {
  if (key.empty()) return true;
  if (op == pref_get_op_) {
    if (event.kind == CMUX_SHIM_PREF_CHANGED) return NamesPref(key, event);
    // A tab of a profile not known before may have opened.
    return event.kind == CMUX_SHIM_AFTER_CREATED;
  }
  switch (ScopeOf(event)) {
    case MirrorScope::kNone:
      return false;
    case MirrorScope::kTab:
      return IsTab(key, event.browser);
    case MirrorScope::kWindow:
      if (IsTab(key, event.browser)) return true;
      return event.a != 0 && key[0].type == control::Type::kI32 &&
             WindowOf(static_cast<int32_t>(key[0].integer)) == event.a;
    case MirrorScope::kWindowKey:
      return IsTab(key, event.a);
    case MirrorScope::kProfile:
      return true;
  }
  return false;
}

void HostMirror::BeforeProduce(uint16_t op, const MirrorKey& key, const MirrorEvent* cause) {
  if (op != pref_get_op_ || !watch_pref_) return;
  // The watch that sent this PREF_CHANGED is in place.
  if (cause != nullptr && cause->kind == CMUX_SHIM_PREF_CHANGED) return;
  if (key.size() != 2 || key[0].type != control::Type::kStr || key[1].type != control::Type::kStr) return;
  // 0 (a profile not known yet, a name not allowed) leaves the key to the
  // next AFTER_CREATED; the value pushed now is the shim's NULL.
  watch_pref_(key[0].bytes.c_str(), key[1].bytes.c_str());
}

void HostMirror::Track(const MirrorEvent& event) {
  switch (event.kind) {
    case CMUX_SHIM_AFTER_CREATED:
      // a = 0: a popup Chromium has not placed yet; TAB_EVENT inserted places it.
      if (event.a != 0) window_of_[event.browser] = event.a;
      return;
    case CMUX_SHIM_BEFORE_CLOSE:
      window_of_.erase(event.browser);
      return;
    case CMUX_SHIM_TAB_EVENT:
      break;
    default:
      return;
  }
  switch (event.request) {
    case kTabInserted:
    case kTabMoved:
      if (event.a != 0) window_of_[event.browser] = event.a;
      return;
    case kTabRemoved: {
      // Removed from window a; a later inserted names its next window.
      auto found = window_of_.find(event.browser);
      if (found != window_of_.end() && found->second == event.a) window_of_.erase(found);
      return;
    }
    case kTabWindowDestroyed:
      for (auto it = window_of_.begin(); it != window_of_.end();) {
        it = it->second == event.a ? window_of_.erase(it) : std::next(it);
      }
      return;
    default:
      return;
  }
}

int64_t HostMirror::WindowOf(int32_t browser) const {
  auto found = window_of_.find(browser);
  return found == window_of_.end() ? 0 : found->second;
}

}  // namespace cmux_host
