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
          (path == "/webstore" || (path.size() >= 10 && path.substr(0, 10) == "/webstore/")));
}

inline bool IsWebStoreURLParts(std::string_view scheme, std::string_view host, std::string_view path) {
  return scheme == "https" && IsWebStoreHost(host, path);
}

inline bool IsWebStoreCrxURLParts(std::string_view scheme, std::string_view host, std::string_view path) {
  return scheme == "https" && host == "clients2.google.com" && path == "/service/update2/crx";
}

inline bool IsWebStoreCrxDownloadURL(std::string_view url) {
  const size_t scheme_end = url.find("://");
  if (scheme_end == std::string_view::npos) return false;
  const size_t authority_start = scheme_end + 3;
  const size_t path_start = url.find('/', authority_start);
  if (path_start == std::string_view::npos) return false;
  const std::string_view host = url.substr(authority_start, path_start - authority_start);
  const size_t path_end = url.find_first_of("?#", path_start);
  const std::string_view path = url.substr(
      path_start, path_end == std::string_view::npos ? url.size() - path_start : path_end - path_start);
  return IsWebStoreCrxURLParts(url.substr(0, scheme_end), host, path);
}

inline bool ShouldDeferToCEFExtensionInstaller(std::string_view original_url, std::string_view current_url) {
  return IsWebStoreCrxDownloadURL(original_url) || IsWebStoreCrxDownloadURL(current_url);
}

}  // namespace cmux_shim
