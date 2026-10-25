// Permission prompts (CefPermissionHandler). Chromium's own bubble anchors to
// a toolbar cmux never shows, so a request it would ask about waits until it
// times out. The kinds the host asks about in its prompt bar
// (kHostPermissions) go to the host as PERMISSION_PROMPT, answered with
// cmux_shim_permission_continue; every other kind keeps Chromium's default.
// Chromium persists Accept and Deny in its own content settings.

#include <map>

#include "cmux_page_path.h"
#include "include/cef_permission_handler.h"
#include "shim_internal.h"

namespace cmux_shim {

namespace {

// Location only: notifications are off (disable-notifications, CEFSwitches).
constexpr uint32_t kHostPermissions = CEF_PERMISSION_TYPE_GEOLOCATION;

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
}

}  // namespace cmux_shim

using namespace cmux_shim;

extern "C" {

int cmux_shim_permission_continue(int prompt_token, int result) {
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
