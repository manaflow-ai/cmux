// A page's links to other apps (cx-d0d.22): a main-frame navigation to a
// scheme neither Chromium nor cmux loads (mailto:, tel:, an app's own
// scheme) is cancelled before it starts and reported as EXTERNAL_URL, with
// whether the user's gesture started it and whether a server redirect led there; the host opens it in its app or
// asks first (BrowserExternalApps). Left to Chromium, the navigation would
// fail with ERR_UNKNOWN_URL_SCHEME and commit its error page over the page.
// web+ and ext+ schemes stay Chromium's (registered protocol handlers).
#pragma once

#include <string>

#include "cmux_page_path.h"
#include "local_file_handoff.h"

namespace cmux_shim {

inline bool IsExternalAppURL(const std::string& url) {
  const size_t colon = url.find(':');
  if (colon == std::string::npos || colon == 0) return false;
  const std::string scheme = LowerASCII(url.substr(0, colon));
  static const char* const kLoaded[] = {
      "http", "https", "ws", "wss", "file", "about", "data", "blob", "filesystem", "javascript",
      "chrome", "chrome-extension", "chrome-untrusted", "chrome-search", "chrome-error", "chrome-native",
      "devtools", "view-source", "isolated-app", kCmuxPageScheme,
  };
  for (const char* loaded : kLoaded) {
    if (scheme == loaded) return false;
  }
  return scheme.rfind("web+", 0) != 0 && scheme.rfind("ext+", 0) != 0;
}

}  // namespace cmux_shim
