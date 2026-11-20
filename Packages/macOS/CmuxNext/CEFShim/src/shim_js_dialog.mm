// A page's alert, confirm and prompt go to the host app while it asks for
// them (cmux_shim_set_js_dialogs), which shows them as its own dialog in the
// tab. cmux asks while its pages are in its window's view tree (fork API 36):
// the fork cancels a JavaScript dialog of an in-tree page that no CEF handler
// takes, because Chrome's own dialog would anchor to the page's headless
// window (fork-notes 4.x, cmux::IsInvisiblePageWindow). Off, Chromium shows
// its own dialog as before.

#include <map>

#include "include/cef_parser.h"
#include "shim_internal.h"

namespace cmux_shim {

namespace {

bool& routed() {
  static bool on = false;
  return on;
}

struct JSDialogQuestion {
  int browser_id;
  CefRefPtr<CefJSDialogCallback> callback;
};

std::map<int, JSDialogQuestion>& questions() {
  static std::map<int, JSDialogQuestion> map;
  return map;
}

}  // namespace

bool AskJSDialog(int browser_id, const std::string& origin, int type, const std::string& message,
                 const std::string& default_text, CefRefPtr<CefJSDialogCallback> callback) {
  if (!routed()) return false;
  static int next = 1;
  const int token = next++;
  questions()[token] = {browser_id, callback};
  CefRefPtr<CefDictionaryValue> text = CefDictionaryValue::Create();
  text->SetString("message", message);
  text->SetString("default", default_text);
  CefRefPtr<CefValue> value = CefValue::Create();
  value->SetDictionary(text);
  Emit(CMUX_SHIM_JS_DIALOG, browser_id, token, type, 0, origin, CefWriteJSON(value, JSON_WRITER_DEFAULT).ToString());
  return true;
}

bool DropJSDialogs(int browser_id) {
  bool dropped = false;
  auto& map = questions();
  for (auto it = map.begin(); it != map.end();) {
    if (it->second.browser_id == browser_id) {
      it = map.erase(it);
      dropped = true;
    } else {
      ++it;
    }
  }
  return dropped;
}

}  // namespace cmux_shim

using namespace cmux_shim;

extern "C" {

void cmux_shim_set_js_dialogs(int enabled) {
  routed() = enabled != 0;
}

int cmux_shim_js_dialog_reply(int token, int accept, const char* text) {
  auto& map = questions();
  auto it = map.find(token);
  if (it == map.end()) return 0;
  // Taken first: Continue can re-enter the dialog handler (OnResetDialogState).
  CefRefPtr<CefJSDialogCallback> callback = it->second.callback;
  map.erase(it);
  callback->Continue(accept != 0, CefString(text ? text : ""));
  return 1;
}

}  // extern "C"
