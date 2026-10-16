// Pure URL policy for Chrome Web Store requests and CRX downloads.
//
// Keep this separate from CEF's URL parser so the security-sensitive routing
// decision can be tested without downloading or embedding the CEF artifact.
#pragma once

#include <string_view>

namespace cmux_shim {

inline bool IsWebStoreHost(std::string_view host, std::string_view path) {
  // chrome.google.com/webstore is the legacy origin. It still appears in
  // redirects and in links copied from Chrome, so it needs the same headers
  // as chromewebstore.google.com or the store can remain on its spinner page.
  return host == "chromewebstore.google.com" ||
         (host == "chrome.google.com" &&
          (path == "/webstore" || path.starts_with("/webstore/")));
}

inline bool IsWebStoreURLParts(std::string_view scheme, std::string_view host, std::string_view path) {
  return scheme == "https" && IsWebStoreHost(host, path);
}

inline bool IsWebStoreCrxURLParts(std::string_view scheme, std::string_view host, std::string_view path) {
  return scheme == "https" && host == "clients2.google.com" && path == "/service/update2/crx";
}

}  // namespace cmux_shim
