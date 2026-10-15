// Permission prompts (CefPermissionHandler). Chromium's own bubble anchors to
// a toolbar cmux never shows, so a request it would ask about waits until it
// times out. In cmux Classic every request goes to the host as
// PERMISSION_PROMPT (kHostPermissions is every kind), answered with
// cmux_shim_permission_continue: the host's policy asks about camera,
// microphone and clipboard read in its prompt strip and denies the rest
// (BrowserPagePermissionPolicy). Chromium persists Accept and Deny in its own
// content settings; the host resets the answers it does not remember.

#include <map>

#include "include/cef_permission_handler.h"
#include "shim_internal.h"

namespace cmux_shim {

namespace {

// Every kind: a request left to Chromium would wait on an invisible bubble.
constexpr uint32_t kHostPermissions = ~static_cast<uint32_t>(0);

// Waiting prompts by token (prompt id + 1), UI thread. Never destroyed at
// exit (its callbacks would outlive CefShutdown); ForgetPermissionPrompts
// empties it before shutdown.
std::map<int, CefRefPtr<CefPermissionPromptCallback>>& prompts() {
  static auto* table = new std::map<int, CefRefPtr<CefPermissionPromptCallback>>();
  return *table;
}

int TokenOf(uint64_t prompt_id) {
  return static_cast<int>(prompt_id % 0x7fffffff) + 1;
}

// Media access requests (getUserMedia): Chromium asks the client before its
// own prompt machinery, which never shows for cmux tabs. They reach the host
// as PERMISSION_PROMPT too, with negative tokens (prompt tokens are
// positive) and the camera/microphone prompt bits, answered with the same
// cmux_shim_permission_continue. A media answer is not saved by Chromium.
struct MediaRequest {
  CefRefPtr<CefMediaAccessCallback> callback;
  uint32_t requested = 0;
};

std::map<int, MediaRequest>& media_requests() {
  static auto* table = new std::map<int, MediaRequest>();
  return *table;
}

int NextMediaToken() {
  static int next = 0;
  next = next <= -0x7fffffff ? -1 : next - 1;
  return next;
}

class Handler : public CefPermissionHandler {
 public:
  bool OnShowPermissionPrompt(CefRefPtr<CefBrowser> browser, uint64_t prompt_id, const CefString& requesting_origin,
                              uint32_t requested_permissions,
                              CefRefPtr<CefPermissionPromptCallback> callback) override {
    // A request that groups a host kind with another stays with Chromium.
    if (!browser || requested_permissions == 0 || (requested_permissions & ~kHostPermissions) != 0) {
      return false;
    }
    const int token = TokenOf(prompt_id);
    prompts()[token] = callback;
    Emit(CMUX_SHIM_PERMISSION_PROMPT, browser->GetIdentifier(), token, requested_permissions, 0,
         requesting_origin.ToString());
    return true;
  }

  bool OnRequestMediaAccessPermission(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame>,
                                      const CefString& requesting_origin, uint32_t requested_permissions,
                                      CefRefPtr<CefMediaAccessCallback> callback) override {
    if (!browser || requested_permissions == 0) return false;
    // Desktop capture has no cmux prompt: denied (BrowserPagePermissionPolicy).
    if (requested_permissions &
        (CEF_MEDIA_PERMISSION_DESKTOP_AUDIO_CAPTURE | CEF_MEDIA_PERMISSION_DESKTOP_VIDEO_CAPTURE)) {
      callback->Cancel();
      return true;
    }
    uint32_t prompt_bits = 0;
    if (requested_permissions & CEF_MEDIA_PERMISSION_DEVICE_VIDEO_CAPTURE) prompt_bits |= CEF_PERMISSION_TYPE_CAMERA_STREAM;
    if (requested_permissions & CEF_MEDIA_PERMISSION_DEVICE_AUDIO_CAPTURE) prompt_bits |= CEF_PERMISSION_TYPE_MIC_STREAM;
    const int token = NextMediaToken();
    media_requests()[token] = MediaRequest{callback, requested_permissions};
    Emit(CMUX_SHIM_PERMISSION_PROMPT, browser->GetIdentifier(), token, prompt_bits, 0, requesting_origin.ToString());
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

void ForgetPermissionPrompts() {
  prompts().clear();
  for (auto& entry : media_requests()) entry.second.callback->Cancel();
  media_requests().clear();
}

}  // namespace cmux_shim

using namespace cmux_shim;

extern "C" {

int cmux_shim_permission_continue(int prompt_token, int result) {
  if (prompt_token < 0) {
    auto media = media_requests().find(prompt_token);
    if (media == media_requests().end()) return 0;
    MediaRequest request = media->second;
    media_requests().erase(media);
    // Accept grants what the page asked for; deny and no answer refuse this
    // request only (Chromium saves no media answer, so no embargo either).
    if (result == 1) {
      request.callback->Continue(request.requested);
    } else {
      request.callback->Cancel();
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
