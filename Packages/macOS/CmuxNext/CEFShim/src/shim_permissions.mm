// Permission prompts (CefPermissionHandler). Chromium's own bubble anchors to
// a toolbar cmux never shows, so a request it would ask about waits until it
// times out. The requests the host asks about (permission_prompt_policy.h:
// location, and with the feature chromiumPermissionPromptsFromData every
// cef_permission_request_types_t and screen sharing) go to the host as
// PERMISSION_PROMPT, answered with cmux_shim_permission_continue; every other
// request keeps Chromium's default. Chromium persists Accept and Deny of a
// permission prompt in its own content settings; a screen share is asked
// each time, as Chrome does.

#include <map>

#include "cmux_page_path.h"
#include "include/cef_command_line.h"
#include "include/cef_permission_handler.h"
#include "permission_prompt_policy.h"
#include "shim_internal.h"

namespace cmux_shim {

namespace {

// One request waiting for the host: a permission prompt (Chromium's prompt id)
// or a media access request (the bits it asked for).
struct Waiting {
  uint64_t prompt_id = 0;
  CefRefPtr<CefPermissionPromptCallback> prompt;
  CefRefPtr<CefMediaAccessCallback> media;
  uint32_t media_requested = 0;
};

// Waiting requests by token, UI thread. Never destroyed at exit (its
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
  bool OnRequestMediaAccessPermission(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame>,
                                      const CefString& requesting_origin, uint32_t requested_permissions,
                                      CefRefPtr<CefMediaAccessCallback> callback) override {
    if (!browser || !MediaGoesToHost(EveryKindToHost(), requested_permissions)) return false;
    const int token = NextPermissionToken(last_token(), waiting());
    Waiting& entry = waiting()[token];
    entry.media = callback;
    entry.media_requested = requested_permissions;
    Emit(CMUX_SHIM_PERMISSION_PROMPT, browser->GetIdentifier(), token, MediaPromptBits(requested_permissions), 0,
         requesting_origin.ToString());
    return true;
  }

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
    Waiting& entry = waiting()[token];
    entry.prompt_id = prompt_id;
    entry.prompt = callback;
    Emit(CMUX_SHIM_PERMISSION_PROMPT, browser->GetIdentifier(), token, requested_permissions, 0,
         requesting_origin.ToString());
    return true;
  }

  // Chromium ended the prompt itself (navigation, tab closed) or after the
  // host's answer: the host drops a question still showing.
  void OnDismissPermissionPrompt(CefRefPtr<CefBrowser> browser, uint64_t prompt_id,
                                 cef_permission_request_result_t) override {
    for (auto it = waiting().begin(); it != waiting().end(); ++it) {
      if (!it->second.prompt || it->second.prompt_id != prompt_id) continue;
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
  const Waiting entry = it->second;
  waiting().erase(it);
  if (entry.media) {
    entry.media->Continue(MediaAllowed(result, entry.media_requested));
    return 1;
  }
  switch (result) {
    case 1: entry.prompt->Continue(CEF_PERMISSION_RESULT_ACCEPT); break;
    case 2: entry.prompt->Continue(CEF_PERMISSION_RESULT_DENY); break;
    // No answer (the tab closed): never DISMISS, which Chromium counts toward
    // blocking the site for days (embargo). The request ends, unanswered,
    // when the page goes away.
    default: break;
  }
  return 1;
}

}  // extern "C"
