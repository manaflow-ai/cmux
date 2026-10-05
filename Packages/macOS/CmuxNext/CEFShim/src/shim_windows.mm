// Chromium never opens a window of its own: the window request handler (fork
// API 8), popup dispositions for the host's adoption, and the Chromium commands
// that would open a Chromium window.

#include <chrono>

#include "download_state.h"
#include "shim_internal.h"

namespace cmux_shim {

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

int WindowRequestTrampoline(void*, const void* raw) {
  Host& h = host();
  const auto* request = static_cast<const ForkWindowRequest*>(raw);
  if (!h.window_request || !request || request->size < sizeof(ForkWindowRequest)) {
    return 0;
  }
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
  // already shows it.
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

void InstallWindowRequestHandler() {
  ForkApi& api = fork_api();
  if (!api.set_window_request_handler) {
    return;
  }
  api.set_window_request_handler(host().window_request ? WindowRequestTrampoline : nullptr, nullptr);
}

}  // namespace cmux_shim

using namespace cmux_shim;

extern "C" {

void cmux_shim_set_window_request_handler(cmux_shim_window_request_fn handler) {
  host().window_request = handler;
  InstallWindowRequestHandler();
}

int cmux_shim_foreign_browser_count(void) {
  return fork_api().foreign_browser_count ? fork_api().foreign_browser_count() : -1;
}

}  // extern "C"
