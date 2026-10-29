// Permission prompts (CefPermissionHandler). Chromium's own bubble anchors to
// a toolbar cmux never shows, so a request it would ask about waits until it
// times out. The requests the host asks about (permission_prompt_policy.h:
// location, and with the feature chromiumPermissionPromptsFromData every
// cef_permission_request_types_t, camera and microphone included) go to the
// host as PERMISSION_PROMPT, answered with cmux_shim_permission_continue;
// every other request keeps Chromium's default. Chromium persists Accept and
// Deny in its own content settings. Media access is not handled here:
// Chromium's MediaStreamDevicesController asks for camera and microphone
// through OnShowPermissionPrompt, and screen sharing keeps Chromium's
// desktop media picker path.

#include <map>

#include "cmux_page_path.h"
#include "include/cef_command_line.h"
#include "include/cef_permission_handler.h"
#include "permission_prompt_policy.h"
#include "shim_internal.h"

namespace cmux_shim {

namespace {

// One permission prompt waiting for the host, with Chromium's prompt id.
struct Waiting {
  uint64_t prompt_id = 0;
  CefRefPtr<CefPermissionPromptCallback> prompt;
};

// Waiting prompts by token, UI thread. Never destroyed at exit (its
// callbacks would outlive CefShutdown); ForgetPermissionPrompts empties it
// before shutdown.
std::map<int, Waiting>& waiting() {
  static auto* table = new std::map<int, Waiting>();
  return *table;
}

int& last_token() {
  static int last = 0;
  return last;
}

// The feature, read once from the browser's feature lists: the command line
// is fixed after CefInitialize.
bool EveryKindToHost() {
  static const bool every = [] {
    CefRefPtr<CefCommandLine> command_line = CefCommandLine::GetGlobalCommandLine();
    if (!command_line) return false;
    return EveryKindFromFeatureLists(command_line->GetSwitchValue("enable-features").ToString(),
                                     command_line->GetSwitchValue("disable-features").ToString());
  }();
  return every;
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
    if (!browser || !PromptGoesToHost(EveryKindToHost(), requested_permissions)) return false;
    const int token = NextPermissionToken(last_token(), waiting());
    waiting()[token] = Waiting{prompt_id, callback};
    Emit(CMUX_SHIM_PERMISSION_PROMPT, browser->GetIdentifier(), token, requested_permissions, 0,
         requesting_origin.ToString());
    return true;
  }

  // Chromium ended the prompt itself (navigation, tab closed) or after the
  // host's answer: the host drops a question still showing.
  void OnDismissPermissionPrompt(CefRefPtr<CefBrowser> browser, uint64_t prompt_id,
                                 cef_permission_request_result_t) override {
    for (auto it = waiting().begin(); it != waiting().end(); ++it) {
      if (it->second.prompt_id != prompt_id) continue;
      const int token = it->first;
      waiting().erase(it);
      Emit(CMUX_SHIM_PERMISSION_DISMISSED, browser ? browser->GetIdentifier() : 0, token);
      return;
    }
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
  waiting().clear();
}

}  // namespace cmux_shim

using namespace cmux_shim;

extern "C" {

int cmux_shim_permission_continue(int prompt_token, int result) {
  auto it = waiting().find(prompt_token);
  if (it == waiting().end()) return 0;
  CefRefPtr<CefPermissionPromptCallback> callback = it->second.prompt;
  waiting().erase(it);
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
