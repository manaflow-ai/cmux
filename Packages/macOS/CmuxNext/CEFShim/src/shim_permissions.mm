// Permission prompts (CefPermissionHandler). Chromium's own bubble anchors to
// a toolbar cmux never shows, so a request it would ask about waits until it
// times out. The kinds the host asks about in its prompt bar
// (kHostPermissions, and notifications alone) go to the host as PERMISSION_PROMPT, answered
// with cmux_shim_permission_continue; every other kind keeps Chromium's default
// (permission_prompt_policy.h).
// Chromium persists Accept and Deny in its own content settings.

#include <map>

#include "cmux_page_path.h"
#include "include/cef_permission_handler.h"
#include "permission_prompt_policy.h"
#include "shim_internal.h"

namespace cmux_shim {

namespace {

// permission_prompt_policy.h names CEF's bits without CEF's headers.
static_assert(kPermissionGeolocation == CEF_PERMISSION_TYPE_GEOLOCATION, "geolocation bit");
static_assert(kPermissionNotifications == CEF_PERMISSION_TYPE_NOTIFICATIONS, "notifications bit");
static_assert(kPermissionCamera == CEF_PERMISSION_TYPE_CAMERA_STREAM, "camera bit");
static_assert(kPermissionMicrophone == CEF_PERMISSION_TYPE_MIC_STREAM, "microphone bit");
static_assert(kPermissionCameraPanTiltZoom == CEF_PERMISSION_TYPE_CAMERA_PAN_TILT_ZOOM, "camera pan-tilt-zoom bit");

// Waiting prompts by token (prompt id + 1), UI thread. Never destroyed at
// exit (its callbacks would outlive CefShutdown); ForgetPermissionPrompts
// empties it before shutdown.
std::map<int, CefRefPtr<CefPermissionPromptCallback>>& prompts() {
  static auto* table = new std::map<int, CefRefPtr<CefPermissionPromptCallback>>();
  return *table;
}

static_assert(kMediaDesktopAudioCapture == CEF_MEDIA_PERMISSION_DESKTOP_AUDIO_CAPTURE, "desktop audio bit");
static_assert(kMediaDesktopVideoCapture == CEF_MEDIA_PERMISSION_DESKTOP_VIDEO_CAPTURE, "desktop video bit");

// A waiting getDisplayMedia() by token, UI thread: the allowed bits and the callback. Tokens start
// above every permission-prompt token (those are below 0x7fffffff), so the two tables never clash.
struct DisplayCaptureRequest {
  uint32_t grant;
  CefRefPtr<CefMediaAccessCallback> callback;
};
std::map<int, DisplayCaptureRequest>& displayCaptures() {
  static auto* table = new std::map<int, DisplayCaptureRequest>();
  return *table;
}
int nextDisplayCaptureToken = 0x40000000;

int TokenOf(uint64_t prompt_id) {
  return static_cast<int>(prompt_id % 0x7fffffff) + 1;
}

class Handler : public CefPermissionHandler {
 public:
  bool OnShowPermissionPrompt(CefRefPtr<CefBrowser> browser, uint64_t prompt_id, const CefString& requesting_origin,
                              uint32_t requested_permissions,
                              CefRefPtr<CefPermissionPromptCallback> callback) override {
    // A cmux page reaching its own loopback daemon: granted at once (cmux_page_path.h).
    if (GrantsCmuxPageLocalNetwork(requesting_origin.ToString(), requested_permissions)) {
      callback->Continue(CEF_PERMISSION_RESULT_ACCEPT);
      return true;
    }
    switch (RoutePermissionPrompt(requested_permissions)) {
      case PermissionPromptRoute::kChromium:
        return false;
      case PermissionPromptRoute::kHost:
        break;
    }
    if (!browser) return false;
    const int token = TokenOf(prompt_id);
    prompts()[token] = callback;
    Emit(CMUX_SHIM_PERMISSION_PROMPT, browser->GetIdentifier(), token, requested_permissions, 0,
         requesting_origin.ToString());
    return true;
  }

  // getDisplayMedia(): the host asks in its prompt bar and answers with cmux_shim_permission_continue.
  // Every request ends: granted the desktop kinds it named, or cancelled (the page rejects with
  // NotAllowedError). Any other media request keeps Chromium's default.
  bool OnRequestMediaAccessPermission(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame>,
                                      const CefString& requesting_origin, uint32_t requested_permissions,
                                      CefRefPtr<CefMediaAccessCallback> callback) override {
    if (!IsDisplayCaptureRequest(requested_permissions)) return false;
    if (!browser) {
      callback->Cancel();
      return true;
    }
    const int token = ++nextDisplayCaptureToken;
    displayCaptures()[token] = {DisplayCaptureGrant(requested_permissions), callback};
    Emit(CMUX_SHIM_PERMISSION_PROMPT, browser->GetIdentifier(), token, kPermissionDisplayCapture, 0,
         requesting_origin.ToString());
    return true;
  }

  // Chromium ended the prompt itself (navigation, tab closed) or after the
  // host's answer: the host drops a question still showing.
  void OnDismissPermissionPrompt(CefRefPtr<CefBrowser> browser, uint64_t prompt_id,
                                 cef_permission_request_result_t) override {
    const int token = TokenOf(prompt_id);
    if (prompts().erase(token) == 0) return;
    Emit(CMUX_SHIM_PERMISSION_DISMISSED, browser ? browser->GetIdentifier() : 0, token);
  }

 private:
  IMPLEMENT_REFCOUNTING(Handler);
};

}  // namespace

CefRefPtr<CefPermissionHandler> PermissionHandler() {
  static CefRefPtr<CefPermissionHandler> handler = new Handler();
  return handler;
}

namespace {
// Waiting HTTP sign-ins by token, UI thread (never destroyed at exit, like prompts()).
std::map<int, CefRefPtr<CefAuthCallback>>& authPrompts() {
  static auto* table = new std::map<int, CefRefPtr<CefAuthCallback>>();
  return *table;
}
int nextAuthToken = 0;
}  // namespace

int AddAuthPrompt(CefRefPtr<CefAuthCallback> callback) {
  const int token = ++nextAuthToken;
  authPrompts()[token] = callback;
  return token;
}

int ContinueAuthPrompt(int token, const char* user, const char* password) {
  auto it = authPrompts().find(token);
  if (it == authPrompts().end()) return 0;
  CefRefPtr<CefAuthCallback> callback = it->second;
  authPrompts().erase(it);
  if (user) {
    callback->Continue(user, password ? password : "");
  } else {
    callback->Cancel();  // the server's 401 page loads
  }
  return 1;
}

void ForgetAuthPrompts() {
  for (auto& entry : authPrompts()) entry.second->Cancel();
  authPrompts().clear();
}

void ForgetPermissionPrompts() {
  ForgetAuthPrompts();
  prompts().clear();
  for (auto& entry : displayCaptures()) entry.second.callback->Cancel();
  displayCaptures().clear();
}

}  // namespace cmux_shim

using namespace cmux_shim;

extern "C" {

int cmux_shim_auth_continue(int token, const char* user, const char* password) {
  return cmux_shim::ContinueAuthPrompt(token, user, password);
}

int cmux_shim_permission_continue(int prompt_token, int result) {
  auto capture = displayCaptures().find(prompt_token);
  if (capture != displayCaptures().end()) {
    DisplayCaptureRequest request = capture->second;
    displayCaptures().erase(capture);
    if (result == 1) {
      request.callback->Continue(request.grant);
    } else {
      request.callback->Cancel();  // never left pending: the page rejects
    }
    return 1;
  }
  auto it = prompts().find(prompt_token);
  if (it == prompts().end()) return 0;
  CefRefPtr<CefPermissionPromptCallback> callback = it->second;
  prompts().erase(it);
  switch (result) {
    case 1: callback->Continue(CEF_PERMISSION_RESULT_ACCEPT); break;
    case 2: callback->Continue(CEF_PERMISSION_RESULT_DENY); break;
    // No answer (the tab closed): never DISMISS, which Chromium counts toward
    // blocking the site for days (embargo). The request ends, unanswered,
    // when the page goes away.
    default: break;
  }
  return 1;
}

}  // extern "C"
