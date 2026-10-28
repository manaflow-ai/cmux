// Chromium never opens a window of its own: the window request handler (fork
// API 8) or, with none installed, the policy cmux pushed
// (window_request_policy.h), popup dispositions for the host's adoption, and
// the Chromium commands that would open a Chromium window. Also the page
// window's resize fence (fork API 32).

#include <limits.h>
#include <stdlib.h>
#include <time.h>
#include <unistd.h>

#include <chrono>
#include <string_view>

#include "download_state.h"
#include "shim_internal.h"
#include "window_request_policy.h"

namespace cmux_shim {

// cmux_cef_shim.h's values, which window_request_policy.h's decision uses.
constexpr bool SameValue(int policy, int header) { return policy == header; }
static_assert(SameValue(window_policy::kInsert, CMUX_SHIM_WINDOW_INSERT));
static_assert(SameValue(window_policy::kOpenInNewTab, CMUX_SHIM_WINDOW_OPEN_IN_NEW_TAB));
static_assert(SameValue(window_policy::kLoadInSource, CMUX_SHIM_WINDOW_LOAD_IN_SOURCE));
static_assert(SameValue(window_policy::kDownloadInSource, CMUX_SHIM_WINDOW_DOWNLOAD_IN_SOURCE));
static_assert(SameValue(window_policy::kOffTheRecord, CMUX_SHIM_WINDOW_OFF_THE_RECORD));
static_assert(SameValue(window_policy::kRefuseNoWindow, CMUX_SHIM_WINDOW_REFUSE_NO_WINDOW));
static_assert(SameValue(window_policy::kForeground, CMUX_SHIM_NEW_TAB_FOREGROUND));
static_assert(SameValue(window_policy::kBackground, CMUX_SHIM_NEW_TAB_BACKGROUND));
static_assert(SameValue(window_policy::kLinkPlacement, CMUX_SHIM_NEW_TAB_LINK_PLACEMENT));
static_assert(SameValue(window_policy::kPopup, CMUX_SHIM_NEW_TAB_POPUP));
static_assert(SameValue(window_policy::kNewWindow, CMUX_SHIM_NEW_TAB_NEW_WINDOW));
static_assert(SameValue(window_policy::kCurrentTab, CMUX_SHIM_LINK_CURRENT_TAB));
static_assert(SameValue(window_policy::kBackgroundTab, CMUX_SHIM_LINK_BACKGROUND_TAB));
static_assert(SameValue(window_policy::kForegroundTab, CMUX_SHIM_LINK_FOREGROUND_TAB));
static_assert(SameValue(window_policy::kLinkPlacementAction, CMUX_SHIM_LINK_PLACEMENT));
static_assert(SameValue(window_policy::kNewWindowAction, CMUX_SHIM_LINK_NEW_WINDOW));
static_assert(SameValue(window_policy::kDownload, CMUX_SHIM_LINK_DOWNLOAD));
static_assert(SameValue(window_policy::kPlain, CMUX_SHIM_GESTURE_PLAIN));
static_assert(SameValue(window_policy::kCmd, CMUX_SHIM_GESTURE_CMD));
static_assert(SameValue(window_policy::kCmdShift, CMUX_SHIM_GESTURE_CMD_SHIFT));
static_assert(SameValue(window_policy::kShift, CMUX_SHIM_GESTURE_SHIFT));
static_assert(SameValue(window_policy::kOption, CMUX_SHIM_GESTURE_OPTION));
static_assert(SameValue(window_policy::kMiddle, CMUX_SHIM_GESTURE_MIDDLE));
static_assert(SameValue(window_policy::kMiddleShift, CMUX_SHIM_GESTURE_MIDDLE_SHIFT));
static_assert(SameValue(window_policy::kCandidate, CMUX_SHIM_WINDOW_CANDIDATE));
static_assert(SameValue(window_policy::kLastShown, CMUX_SHIM_WINDOW_LAST_SHOWN));
static_assert(SameValue(window_policy::kVisible, CMUX_SHIM_WINDOW_VISIBLE));
static_assert(SameValue(window_policy::kOffTheRecordStore, CMUX_SHIM_WINDOW_OFF_THE_RECORD_STORE));

namespace {

// cmux_window_request_t of the fork (include/cef_cmux.h, API 8). Plain
// fields only; `size` guards against a smaller struct from another fork.
struct ForkWindowRequest {
  size_t size;
  int kind;
  int disposition;
  int source_browser_id;
  int has_bounds;
  int x;
  int y;
  int width;
  int height;
  int user_gesture;
  const char* url;
  const char* profile_path;
};

WindowPolicy& pushed_window_policy() {
  static WindowPolicy policy;
  return policy;
}

// As CEFRuntime.normalizedPath (resolvingSymlinksInPath), so a reported
// profile directory compares with the stores cmux pushed: symlinks resolved,
// and the /private prefix dropped when the path without it exists.
std::string NormalizedPath(const char* path) {
  if (!path || !*path) return std::string();
  char resolved[PATH_MAX];
  if (!realpath(path, resolved)) return path;
  std::string out = resolved;
  constexpr std::string_view kPrivate = "/private/";
  if (out.rfind(kPrivate, 0) == 0 && std::string_view(path).rfind(kPrivate, 0) != 0 &&
      access(out.c_str() + kPrivate.size() - 1, F_OK) == 0) {
    out.erase(0, kPrivate.size() - 1);
  }
  return out;
}

// NSEvent.timestamp's clock, in ms.
int64_t UptimeMs() {
  return static_cast<int64_t>(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1000000);
}

// Decides `request` with the pushed policy, inside Chromium's navigation,
// and reports the decision (CMUX_SHIM_WINDOW_REQUEST_RESULT) before Chromium
// creates the tab, so cmux knows its placement when the tab arrives.
int DecidePushed(const ForkWindowRequest& request) {
  WindowRequestFacts facts;
  facts.kind = request.kind;
  facts.disposition = request.disposition;
  facts.source = request.source_browser_id;
  facts.user_gesture = request.user_gesture != 0;
  facts.url = request.url ? request.url : "";
  facts.profile_path = NormalizedPath(request.profile_path);
  const WindowDecision decision = DecideWindowRequest(pushed_window_policy(), facts, UptimeMs(),
                                                      [](int browser) { return cmux_shim_tab_window_id(browser); });
  const int anchor = decision.outcome == window_policy::kInsert ? decision.anchor : 0;
  // The low 32 bits; the Chromium Host puts the id it mints for an INSERT's tab in the high ones.
  const int64_t packed = static_cast<int64_t>(decision.outcome & 0xff) |
                         static_cast<int64_t>(decision.new_tab & 0xff) << 8 |
                         static_cast<int64_t>(request.kind & 0xff) << 16 |
                         static_cast<int64_t>(request.disposition & 0x7f) << 24 |
                         static_cast<int64_t>(request.user_gesture ? 1 : 0) << 31;
  std::string where;
  if (request.has_bounds) {
    where = std::to_string(request.x) + "," + std::to_string(request.y) + "," + std::to_string(request.width) + "," +
            std::to_string(request.height);
  }
  where += ";" + decision.store;
  Emit(CMUX_SHIM_WINDOW_REQUEST_RESULT, request.source_browser_id, anchor != 0 ? cmux_shim_tab_window_id(anchor) : 0,
       anchor, packed, facts.url, where);
  return anchor;
}

int WindowRequestTrampoline(void*, const void* raw) {
  Host& h = host();
  const auto* request = static_cast<const ForkWindowRequest*>(raw);
  if (!request || request->size < sizeof(ForkWindowRequest)) {
    return 0;
  }
  if (!h.window_request) return DecidePushed(*request);
  return h.window_request(h.ctx, request->kind, request->disposition, request->source_browser_id,
                          request->has_bounds, request->x, request->y, request->width, request->height,
                          request->user_gesture ? 1 : 0, request->url ? request->url : "", request->profile_path ? request->profile_path : "");
}

PendingPopups& pending_popups() {
  static PendingPopups popups;
  return popups;
}

int64_t NowMs() {
  return std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now().time_since_epoch()).count();
}

}  // namespace

void RememberPopup(int opener, int popup_id, const std::string& url, int disposition, bool user_gesture,
                   const CefPopupFeatures& features) {
  std::string bounds;
  if (features.widthSet || features.heightSet) {
    bounds = std::to_string(features.xSet ? features.x : 0) + "," + std::to_string(features.ySet ? features.y : 0) +
             "," + std::to_string(features.widthSet ? features.width : 0) + "," +
             std::to_string(features.heightSet ? features.height : 0);
  }
  PendingPopup popup;
  popup.popup_id = popup_id;
  popup.url = url;
  popup.disposition = disposition;
  popup.user_gesture = user_gesture;
  popup.features = bounds;
  popup.at_ms = NowMs();
  pending_popups().Remember(opener, std::move(popup));
}

void AbortPopup(int opener, int popup_id) {
  pending_popups().Abort(opener, popup_id);
}

int64_t TakePopup(CefRefPtr<CefBrowser> browser, std::string* features, std::string* url) {
  const int opener = browser->GetHost()->GetOpenerIdentifier();
  if (opener <= 0) {
    return 0;
  }
  // The new tab's pending navigation is the popup's target, when Chromium
  // already shows it. A tab with no visible URL here takes no popup
  // (PendingPopups::Take): no disposition, no user gesture.
  std::string visible;
  if (CefRefPtr<CefNavigationEntry> entry = browser->GetHost()->GetVisibleNavigationEntry()) {
    visible = entry->GetURL().ToString();
  }
  int disposition = 0;
  PendingPopup popup;
  if (pending_popups().Take(opener, visible, NowMs(), &popup)) {
    disposition = (popup.disposition & 0xffff) | (popup.user_gesture ? 1 << 16 : 0);
    *features = popup.features;
    *url = popup.url;
  }
  return (static_cast<int64_t>(opener) << 32) | static_cast<uint32_t>(disposition);
}

void ForgetPopups(int opener) {
  pending_popups().Forget(opener);
}

bool IsWindowCommand(int command_id) {
  switch (command_id) {
    case 34000:  // IDC_NEW_WINDOW
    case 34001:  // IDC_NEW_INCOGNITO_WINDOW
    case 34052:  // IDC_RESTORE_WINDOW
    case 34055:  // IDC_OPEN_IN_PWA_WINDOW
    case 34056:  // IDC_MOVE_TAB_TO_NEW_WINDOW
    case 35356:  // IDC_OPEN_GUEST_PROFILE
    case 40002:  // IDC_CREATE_SHORTCUT
    case 40006:  // IDC_TASK_MANAGER
    case 40008:  // IDC_FEEDBACK
    case 40134:  // IDC_SHOW_AVATAR_MENU
    case 40254:  // IDC_INSTALL_PWA
      return true;
    default:
      return false;
  }
}

// Always installed: without cmux's handler the pushed policy decides, so the
// fork never falls back to a tab in the requesting tab's window.
void InstallWindowRequestHandler() {
  ForkApi& api = fork_api();
  if (!api.set_window_request_handler) {
    return;
  }
  api.set_window_request_handler(WindowRequestTrampoline, nullptr);
}

}  // namespace cmux_shim

using namespace cmux_shim;

extern "C" {

void cmux_shim_set_window_request_handler(cmux_shim_window_request_fn handler) {
  host().window_request = handler;
  InstallWindowRequestHandler();
}

void cmux_shim_set_window_request_policy(const cmux_shim_window_policy_window* windows, int window_count,
                                         const cmux_shim_window_policy_click* clicks, int click_count,
                                         const char* profile_root, int cmd_click, int cmd_shift_click,
                                         int shift_click, int option_click, int middle_click) {
  WindowPolicy policy;
  for (int i = 0; windows && i < window_count; ++i) {
    WindowPolicyWindow window;
    window.anchor = static_cast<int>(windows[i].anchor_browser_id);
    window.popup_opener = static_cast<int>(windows[i].opener_browser_id);
    window.flags = static_cast<int>(windows[i].flags);
    if (windows[i].store) window.store.assign(windows[i].store, windows[i].store_length);
    // The host names a minted tab it has no browser for as 0: no window to go to.
    if (window.anchor > 0) policy.windows.push_back(std::move(window));
  }
  for (int i = 0; clicks && i < click_count; ++i) {
    if (clicks[i].browser_id <= 0) continue;
    policy.clicks[static_cast<int>(clicks[i].browser_id)] =
        WindowPolicyClick{static_cast<int>(clicks[i].gesture), clicks[i].uptime_ms};
  }
  policy.profile_root = profile_root ? profile_root : "";
  const int actions[5] = {cmd_click, cmd_shift_click, shift_click, option_click, middle_click};
  for (int i = 0; i < 5; ++i) policy.actions[i] = actions[i];
  pushed_window_policy() = std::move(policy);
}

int cmux_shim_foreign_browser_count(void) {
  return fork_api().foreign_browser_count ? fork_api().foreign_browser_count() : -1;
}

int cmux_shim_browser_set_resize_fence(int browser_id, unsigned int fence_port, unsigned int deadline_frames) {
  if (!fork_api().browser_set_resize_fence) return 0;
  return fork_api().browser_set_resize_fence(browser_id, fence_port, deadline_frames);
}

}  // extern "C"
