// Raw DevTools protocol traffic of the host: raw sends, their replies and
// the protocol events of watched browsers (CMUX_SHIM_DEVTOOLS_EVENT), and
// the id rule shared with shim-internal calls (cmux_cef_shim.h): raw sends
// use ids >= 2^30, the shim assigns its own calls ids below 2^30.

#include <cstring>

#include "devtools_message_id.h"
#include "include/cef_parser.h"
#include "shim_internal.h"

namespace cmux_shim {

namespace {

constexpr int kFirstRawDevToolsId = 1 << 30;

// UI thread only.
std::set<int>& watched_browsers() {
  static std::set<int> set;
  return set;
}

// Browsers that made a raw send: their replies must be found and consumed.
std::set<int>& raw_send_browsers() {
  static std::set<int> set;
  return set;
}

std::map<int, int>& internal_ids() {
  static std::map<int, int> map;
  return map;
}

// The integer "id" of a JSON object message, if it has one.
bool MessageId(CefRefPtr<CefDictionaryValue> dict, int* id) {
  if (!dict->HasKey("id") || dict->GetType("id") != VTYPE_INT) return false;
  *id = dict->GetInt("id");
  return true;
}

}  // namespace

int NextInternalDevToolsId(int browser_id) {
  int& last = internal_ids()[browser_id];
  // Explicit ids (never ExecuteDevToolsMethod's own counter), so a
  // shim-internal call can never reach the raw range. A browser that used
  // up 2^30 - 1 calls gets no more (fail closed).
  if (last >= kFirstRawDevToolsId - 1) return 0;
  return ++last;
}

bool ForwardDevToolsMessage(int browser_id, const void* message, size_t message_size) {
  const bool watched = watched_browsers().count(browser_id) > 0;
  if (!watched && !raw_send_browsers().count(browser_id)) return false;
  if (!message || message_size == 0) return false;
  // A top-level scan, not a full parse: a full parse refuses valid protocol
  // output (lone surrogates, deep nesting) and costs a parse per message.
  long long id = 0;
  const DevToolsIdKind kind = TopLevelDevToolsId(static_cast<const char*>(message), message_size, &id);
  if (kind == DevToolsIdKind::kInvalid) return false;
  const std::string raw(static_cast<const char*>(message), message_size);
  if (kind == DevToolsIdKind::kInt) {
    // A reply. Raw-send replies are the host's alone; shim-internal
    // replies go on to OnDevToolsMethodResult (DEVTOOLS_RESULT).
    if (id < kFirstRawDevToolsId) return false;
    Emit(CMUX_SHIM_DEVTOOLS_EVENT, browser_id, 0, 0, 0, raw);
    return true;
  }
  if (watched) Emit(CMUX_SHIM_DEVTOOLS_EVENT, browser_id, 0, 0, 0, raw);
  return false;
}

void ForgetDevToolsProtocol(int browser_id) {
  watched_browsers().erase(browser_id);
  raw_send_browsers().erase(browser_id);
  internal_ids().erase(browser_id);
}

}  // namespace cmux_shim

using namespace cmux_shim;

extern "C" {

void cmux_shim_devtools_watch_events(int browser_id, int enabled) {
  if (enabled && BrowserById(browser_id)) {
    watched_browsers().insert(browser_id);
  } else {
    watched_browsers().erase(browser_id);
  }
}

int cmux_shim_devtools_send(int browser_id, const char* message_json) {
  CefRefPtr<CefBrowser> browser = BrowserById(browser_id);
  if (!browser) return 0;
  if (!message_json || !*message_json) return -1;
  const size_t size = std::strlen(message_json);
  CefRefPtr<CefValue> value = CefParseJSON(message_json, size, JSON_PARSER_RFC);
  if (!value || value->GetType() != VTYPE_DICTIONARY) return -1;
  int id = 0;
  if (!MessageId(value->GetDictionary(), &id) || id < kFirstRawDevToolsId) return -1;
  // The parsed message is sent again as written by CEF: one "id" only (a
  // repeated key kept its last value here, but the protocol would answer
  // with the first, a shim-internal id).
  const std::string canonical = CefWriteJSON(value, JSON_WRITER_DEFAULT).ToString();
  if (canonical.empty()) return -1;
  // Before the send: a reply may arrive while SendDevToolsMessage runs.
  raw_send_browsers().insert(browser_id);
  return browser->GetHost()->SendDevToolsMessage(canonical.data(), canonical.size()) ? 1 : -1;
}

}  // extern "C"
