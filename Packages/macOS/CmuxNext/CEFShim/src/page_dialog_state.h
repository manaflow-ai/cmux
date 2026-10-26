// The wire form of a page's JavaScript dialogs and HTTP authentication, with no CEF
// (scripts/cmux-next/test-shim-page-dialogs-cpp.sh compiles it alone). With
// cmux_shim_set_page_dialogs(1) the shim hands each one to the host
// (CMUX_SHIM_JS_DIALOG, CMUX_SHIM_AUTH) instead of Chromium's tab-modal
// dialog (TabModalDialogManager) or login prompt (LoginHandler), and the host
// answers it once by token. The questions wait in the file choosers' token
// table: answered at most once, and a browser's all at once when Chromium ends
// them.
#pragma once

#include <cstdint>
#include <string>
#include <string_view>

#include "file_dialog_state.h"

namespace cmux_shim {

template <typename Callback>
using PageQuestions = FileDialogs<Callback>;

// JS_DIALOG's s2: the URL of the frame that asks, a newline, then the
// prompt's default text. A URL Chromium formats has no raw newline, so the
// first newline ends it; the default text may hold more.
inline std::string JsDialogDetails(std::string_view frame_url, std::string_view default_text) {
  std::string details(frame_url);
  details += '\n';
  details += default_text;
  return details;
}

// AUTH's b: bit 0 set for a proxy's challenge.
inline int64_t AuthFlags(bool is_proxy) {
  return is_proxy ? 1 : 0;
}

// AUTH's s2: the request's origin URL, the scheme ("basic", "digest", ...)
// and the realm, one per line. A header value has no raw newline, and the
// realm, the one field a server writes freely, comes last.
inline std::string AuthDetails(std::string_view origin_url, std::string_view scheme, std::string_view realm) {
  std::string details(origin_url);
  details += '\n';
  details += scheme;
  details += '\n';
  details += realm;
  return details;
}

}  // namespace cmux_shim
