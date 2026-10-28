// The window request decision the shim makes with the policy cmux pushed
// (cmux_shim_set_window_request_policy, task p01-process-031 of
// plans/cmux-next/chrome-parity/p01-process.md). In the Chromium Host cmux
// cannot answer inside Chromium's navigation, so cmux pushes what the decision
// reads (its pane windows, the link click mapping, the last clicks) and the
// shim decides in the navigation, as Chrome's browser process places a new
// WebContents from state it already holds
// (chrome/browser/ui/browser_navigator.cc, GetBrowserAndTabForDisposition).
// It is CEFWindowPolicy.decide with CEFWindowRequests' store and source
// resolution; CEFShim/tests/window_request_policy_test.cpp checks the cases
// CEFWindowPolicyTests checks in Swift. No CEF, so it compiles alone.
#pragma once

#include <cstdint>
#include <string>
#include <string_view>
#include <unordered_map>
#include <vector>

namespace cmux_shim {

// cmux_cef_shim.h's values (shim_windows.mm checks that they agree).
namespace window_policy {
enum Outcome : int {
  kInsert = 1,
  kOpenInNewTab = 2,
  kLoadInSource = 3,
  kDownloadInSource = 4,
  kOffTheRecord = 5,
  kRefuseNoWindow = 6,
};
enum NewTab : int { kForeground = 0, kBackground = 1, kLinkPlacement = 2, kPopup = 3, kNewWindow = 4 };
enum LinkAction : int {
  kCurrentTab = 0,
  kBackgroundTab = 1,
  kForegroundTab = 2,
  kLinkPlacementAction = 3,
  kNewWindowAction = 4,
  kDownload = 5,
};
enum Gesture : int { kPlain = 0, kCmd = 1, kCmdShift = 2, kShift = 3, kOption = 4, kMiddle = 5, kMiddleShift = 6 };
enum Flag : int { kCandidate = 1, kLastShown = 2, kVisible = 4, kOffTheRecordStore = 8 };
// cmux_window_request_kind_t of the fork.
enum Kind : int { kTabKind = 0, kWindowKind = 1, kPopupKind = 2, kOffTheRecordKind = 3, kAppKind = 4 };
// A click older than this did not cause the request (CEFLinkClicks.clickLifetime).
inline constexpr int64_t kClickLifetimeMs = 1000;
}  // namespace window_policy

struct WindowPolicyWindow {
  int anchor = 0;
  int popup_opener = 0;  // a popup panel: a tab of its opener's pane
  int flags = 0;
  std::string store;
};

struct WindowPolicyClick {
  int gesture = window_policy::kPlain;
  int64_t uptime_ms = 0;
};

struct WindowPolicy {
  std::vector<WindowPolicyWindow> windows;  // by anchor, ascending
  std::unordered_map<int, WindowPolicyClick> clicks;  // by browser
  std::string profile_root;
  // cmd, cmd-shift, shift, option, middle (BrowserLinkClickMapping.chrome until cmux pushes one).
  int actions[5] = {window_policy::kBackgroundTab, window_policy::kForegroundTab, window_policy::kNewWindowAction,
                    window_policy::kDownload, window_policy::kBackgroundTab};
};

struct WindowRequestFacts {
  int kind = window_policy::kWindowKind;
  int disposition = 0;  // cef_window_open_disposition_t
  int source = 0;
  bool user_gesture = false;
  std::string url;
  std::string profile_path;  // normalized as cmux's stores are
};

struct WindowDecision {
  int outcome = window_policy::kRefuseNoWindow;
  int anchor = 0;
  int new_tab = window_policy::kForeground;
  std::string store;  // the request's store

  bool operator==(const WindowDecision&) const = default;
};

namespace window_policy {

enum class Place { kTab, kOpener, kDownload, kChromium };
struct Placement {
  Place place;
  int new_tab;
};

// CEFDisposition.isLinkClick: the dispositions a modified link click produces.
inline bool IsLinkClick(int disposition) {
  return disposition == 3 || disposition == 4 || disposition == 6 || disposition == 7;
}

// CEFLinkClicks.placement: how a link with `disposition` opens. A script's
// request (no user gesture) follows Chrome's mapping and no click.
inline Placement LinkPlacement(int disposition, bool user_gesture, const WindowPolicyClick* click, int64_t now_ms,
                               const int (&actions)[5]) {
  static constexpr int kChrome[5] = {kBackgroundTab, kForegroundTab, kNewWindowAction, kDownload, kBackgroundTab};
  const int* mapping = user_gesture ? actions : kChrome;
  int recent = -1;
  if (user_gesture && click && now_ms >= click->uptime_ms && now_ms - click->uptime_ms <= kClickLifetimeMs) {
    recent = click->gesture;
  }
  int gesture = -1;
  switch (disposition) {
    case 4:  // NEW_BACKGROUND_TAB
      gesture = kCmd;
      break;
    case 3:  // NEW_FOREGROUND_TAB: plain target=_blank unless Shift-Cmd or Shift-middle clicked
      gesture = recent == kCmdShift || recent == kMiddleShift ? recent : -1;
      break;
    case 6:  // NEW_WINDOW
      gesture = kShift;
      break;
    case 7:  // SAVE_TO_DISK
      gesture = kOption;
      break;
    case 5:  // NEW_POPUP
      return {Place::kTab, kPopup};
    case 1:   // CURRENT_TAB
    case 9:   // IGNORE_ACTION
    case 11:  // NEW_PICTURE_IN_PICTURE
      return {Place::kChromium, kForeground};
    default:  // SINGLETON_TAB, SWITCH_TO_TAB, NEW_SPLIT_VIEW, OFF_THE_RECORD, unknown
      return {Place::kTab, kForeground};
  }
  if (gesture < 0) return {Place::kTab, kForeground};
  int action = kCurrentTab;
  switch (gesture) {
    case kCmd: action = mapping[0]; break;
    case kCmdShift:
    case kMiddleShift: action = mapping[1]; break;
    case kShift: action = mapping[2]; break;
    case kOption: action = mapping[3]; break;
    case kMiddle: action = mapping[4]; break;
    default: action = kCurrentTab; break;
  }
  switch (action) {
    case kCurrentTab: return {Place::kOpener, kForeground};
    case kDownload: return {Place::kDownload, kForeground};
    case kBackgroundTab: return {Place::kTab, kBackground};
    case kLinkPlacementAction: return {Place::kTab, kLinkPlacement};
    case kNewWindowAction: return {Place::kTab, kNewWindow};
    default: return {Place::kTab, kForeground};
  }
}

// CEFWindowPolicy.placement: popups keep `kPopup`; a page's link request goes
// through the link mapping; everything else is a selected tab. Opening in or
// downloading from the source needs a source and a URL.
inline Placement RequestPlacement(const WindowRequestFacts& request, const WindowPolicy& policy, int64_t now_ms) {
  const auto click = request.source != 0 ? policy.clicks.find(request.source) : policy.clicks.end();
  const WindowPolicyClick* last = click != policy.clicks.end() ? &click->second : nullptr;
  Placement placement{Place::kTab, kForeground};
  switch (request.kind) {
    case kPopupKind:
      return {Place::kTab, kPopup};
    case kOffTheRecordKind:
      return {Place::kTab, kForeground};
    case kTabKind:
      placement = LinkPlacement(request.disposition, request.user_gesture, last, now_ms, policy.actions);
      break;
    default:  // a window, an app window, or a kind this shim does not know (CEFWindowRequest.Kind's .window)
      if (request.source == 0 || !IsLinkClick(request.disposition)) return {Place::kTab, kForeground};
      placement = LinkPlacement(request.disposition, request.user_gesture, last, now_ms, policy.actions);
      break;
  }
  if ((placement.place == Place::kOpener || placement.place == Place::kDownload) &&
      (request.source == 0 || request.url.empty())) {
    return {Place::kTab, kForeground};
  }
  return placement;
}

// CEFProfileStorage.isPersistentProfilePath: a Profile-* directory right in cmux's profile root.
inline bool IsPersistentStore(std::string_view path, std::string_view root) {
  if (path.empty() || path.front() != '/' || root.empty()) return false;
  const size_t slash = path.rfind('/');
  const std::string_view parent = slash == 0 ? std::string_view("/") : path.substr(0, slash);
  return parent == root && path.substr(slash + 1).rfind("Profile-", 0) == 0;
}

}  // namespace window_policy

// CEFWindowPolicy.decide on a request the shim resolved as CEFWindowRequests
// does: the request's store is the source tab's pane store, else the profile
// directory Chromium reported, which is persistent only when it is a cmux
// Profile-* store. `window_of(browser)` is the Chromium window of a tab (0:
// none); a window's pane holds the source when its anchor shares the source's
// window, and a popup panel's requests go to its opener's pane. Among the
// candidates of the request's store: the one holding the source, else the
// last shown, else a visible one, else the first by anchor.
template <typename WindowOf>
WindowDecision DecideWindowRequest(const WindowPolicy& policy, const WindowRequestFacts& request, int64_t now_ms,
                                   const WindowOf& window_of) {
  using namespace window_policy;
  WindowDecision decision;
  if (request.kind == kOffTheRecordKind || request.disposition == 8) {
    decision.outcome = kOffTheRecord;
    return decision;
  }
  const Placement placement = RequestPlacement(request, policy, now_ms);
  if (placement.place == Place::kOpener || placement.place == Place::kDownload) {
    decision.outcome = placement.place == Place::kOpener ? kLoadInSource : kDownloadInSource;
    return decision;
  }
  decision.new_tab = placement.place == Place::kTab ? placement.new_tab : kForeground;

  const WindowPolicyWindow* source = nullptr;
  if (request.source != 0) {
    if (const int window = window_of(request.source); window != 0) {
      for (const WindowPolicyWindow& each : policy.windows) {
        if (window_of(each.anchor) == window) {
          source = &each;
          break;
        }
      }
    }
  }
  bool persistent = false;
  if (source) {
    decision.store = source->store;
    persistent = (source->flags & kOffTheRecordStore) == 0;
  } else {
    decision.store = request.profile_path;
    persistent = IsPersistentStore(request.profile_path, policy.profile_root);
  }
  const WindowPolicyWindow* holder = source;
  if (holder && holder->popup_opener != 0) {
    const int opener = holder->popup_opener;
    holder = nullptr;
    for (const WindowPolicyWindow& each : policy.windows) {
      if (each.anchor == opener) holder = &each;
    }
  }
  const WindowPolicyWindow* chosen[4] = {nullptr, nullptr, nullptr, nullptr};  // holds source, last shown, visible, first
  for (const WindowPolicyWindow& each : policy.windows) {
    // A window whose anchor names no Chromium window (a tab cmux minted that has no browser yet) takes no tab.
    if ((each.flags & kCandidate) == 0 || each.store != decision.store || window_of(each.anchor) == 0) continue;
    if (!chosen[0] && &each == holder) chosen[0] = &each;
    if (!chosen[1] && (each.flags & kLastShown)) chosen[1] = &each;
    if (!chosen[2] && (each.flags & kVisible)) chosen[2] = &each;
    if (!chosen[3]) chosen[3] = &each;
  }
  for (const WindowPolicyWindow* each : chosen) {
    if (!each) continue;
    decision.outcome = kInsert;
    decision.anchor = each->anchor;
    return decision;
  }
  decision.outcome = persistent ? kOpenInNewTab : kRefuseNoWindow;
  return decision;
}

}  // namespace cmux_shim
