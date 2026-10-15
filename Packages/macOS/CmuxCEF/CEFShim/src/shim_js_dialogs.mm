// JavaScript dialogs (CefJSDialogHandler): alert(), confirm(), prompt() and
// the beforeunload "Leave site?" question. Chromium's own dialog anchors to a
// tab strip cmux never shows, and automation could not see or answer it, so
// a page waiting on confirm() wedged. Every dialog goes to the host as
// JS_DIALOG, answered with cmux_shim_js_dialog_reply; Chromium waits until
// then. When Chromium ends the dialogs itself (the page navigated or closed),
// the host gets JS_DIALOG_DISMISSED for each one still waiting.

#include <cstdio>
#include <iterator>
#include <map>
#include <string>

#include "include/cef_jsdialog_handler.h"
#include "shim_internal.h"

namespace cmux_shim {

namespace {

// JS_DIALOG `a` for a beforeunload question (after cef_jsdialog_type_t's
// alert 0, confirm 1, prompt 2).
constexpr int64_t kBeforeUnloadDialogType = 3;

struct Waiting {
  int browser_id;
  CefRefPtr<CefJSDialogCallback> callback;
};

// Waiting dialogs by token, UI thread. Never destroyed at exit (callbacks
// would outlive CefShutdown); ForgetJSDialogs empties it before shutdown.
std::map<int, Waiting>& dialogs() {
  static auto* table = new std::map<int, Waiting>();
  return *table;
}

int NextToken() {
  static int next = 0;
  next = next == 0x7fffffff ? 1 : next + 1;
  return next;
}

// "\"" + escaped + "\"" for a JSON string value.
std::string JSONString(const std::string& value) {
  std::string out = "\"";
  for (unsigned char c : value) {
    switch (c) {
      case '"': out += "\\\""; break;
      case '\\': out += "\\\\"; break;
      case '\n': out += "\\n"; break;
      case '\r': out += "\\r"; break;
      case '\t': out += "\\t"; break;
      default:
        if (c < 0x20) {
          char buffer[8];
          snprintf(buffer, sizeof buffer, "\\u%04x", c);
          out += buffer;
        } else {
          out += static_cast<char>(c);
        }
    }
  }
  return out + "\"";
}

int Remember(CefRefPtr<CefBrowser> browser, CefRefPtr<CefJSDialogCallback> callback) {
  const int token = NextToken();
  dialogs()[token] = Waiting{browser->GetIdentifier(), callback};
  return token;
}

class Handler : public CefJSDialogHandler {
 public:
  bool OnJSDialog(CefRefPtr<CefBrowser> browser, const CefString& origin_url, JSDialogType dialog_type,
                  const CefString& message_text, const CefString& default_prompt_text,
                  CefRefPtr<CefJSDialogCallback> callback, bool& suppress_message) override {
    suppress_message = false;
    if (!browser) return false;
    const int token = Remember(browser, callback);
    Emit(CMUX_SHIM_JS_DIALOG, browser->GetIdentifier(), token, static_cast<int64_t>(dialog_type), 0,
         message_text.ToString(),
         "{\"origin\":" + JSONString(origin_url.ToString()) +
             ",\"default\":" + JSONString(default_prompt_text.ToString()) + "}");
    return true;
  }

  bool OnBeforeUnloadDialog(CefRefPtr<CefBrowser> browser, const CefString& message_text, bool is_reload,
                            CefRefPtr<CefJSDialogCallback> callback) override {
    if (!browser) return false;
    const int token = Remember(browser, callback);
    Emit(CMUX_SHIM_JS_DIALOG, browser->GetIdentifier(), token, kBeforeUnloadDialogType, is_reload ? 1 : 0,
         message_text.ToString(), "{\"origin\":\"\",\"default\":\"\"}");
    return true;
  }

  // Chromium dropped every dialog of the browser (navigation, close).
  void OnResetDialogState(CefRefPtr<CefBrowser> browser) override {
    if (!browser) return;
    DismissAll(browser->GetIdentifier());
  }

  void OnDialogClosed(CefRefPtr<CefBrowser>) override {}

  static void DismissAll(int browser_id) {
    for (auto it = dialogs().begin(); it != dialogs().end();) {
      if (it->second.browser_id != browser_id) {
        ++it;
        continue;
      }
      const int token = it->first;
      it = dialogs().erase(it);
      Emit(CMUX_SHIM_JS_DIALOG_DISMISSED, browser_id, token);
    }
  }

 private:
  IMPLEMENT_REFCOUNTING(Handler);
};

}  // namespace

CefRefPtr<CefJSDialogHandler> JSDialogHandler() {
  static CefRefPtr<CefJSDialogHandler> handler = new Handler();
  return handler;
}

void ForgetJSDialogs() {
  dialogs().clear();
}

void ForgetJSDialogs(int browser_id) {
  for (auto it = dialogs().begin(); it != dialogs().end();) {
    it = it->second.browser_id == browser_id ? dialogs().erase(it) : std::next(it);
  }
}

}  // namespace cmux_shim

using namespace cmux_shim;

extern "C" {

int cmux_shim_js_dialog_reply(int dialog_token, int accept, const char* user_input) {
  auto it = dialogs().find(dialog_token);
  if (it == dialogs().end()) return 0;
  CefRefPtr<CefJSDialogCallback> callback = it->second.callback;
  dialogs().erase(it);
  callback->Continue(accept != 0, CefString(user_input ? user_input : ""));
  return 1;
}

}  // extern "C"
