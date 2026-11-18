// What cmux sends to the Chrome Web Store (https://chromewebstore.google.com
// only) so the store drops its "Switch to Chrome to install extensions and
// themes" banner (plans/cmux-next/browser.md, "Web Store install").
//
// The banner is a server flag (IJ_values[24] in the page). Measured
// 2026-11-16 with curl against an item page: the flag turns off only when
// the request carries both of Google Chrome's x-browser-copyright and
// x-browser-year headers AND its sec-ch-ua brand list names "Google Chrome".
// The two headers alone (enough until November 2026) and a "cmux" brand do
// not turn it off.
//
// The Google bar on the store also opens a "Switch to Chrome?" card (an
// ogs.google.com callout). Its promo API, ogads-pa.clients6.google.com,
// answers with that card unless the same two headers and brand reach it
// (live on cmux-lawrence-2 2026-11-16, request interception with storage
// cleared each load: the card showed 3/3 without them there, 0/2 with them;
// the brand in navigator.userAgentData or the headers alone did not help).
// cmux sends them to that API only from a store page. Naming "Google Chrome" in sec-ch-ua-full-version-list too
// (which the store asks for) turns it back off, so that header stays
// Chromium's. The store's own install button works either way
// (webstorePrivate), so the brand only removes the banner; no other origin
// sees it, and navigator.userAgentData stays Chromium's.
//
// No CEF dependency, so the test compiles it alone
// (scripts/cmux-next/test-shim-webstore-cpp.sh).
#pragma once

#include <cctype>
#include <string>

namespace cmux_shim {

inline constexpr const char* kWebStoreBrand = "Google Chrome";
inline constexpr const char* kWebStoreHost = "chromewebstore.google.com";
inline constexpr const char* kWebStorePromoHost = "ogads-pa.clients6.google.com";

// The lowercased host of an https URL; empty for any other scheme.
inline std::string HttpsHost(const std::string& url) {
  const std::string scheme = "https://";
  if (url.size() < scheme.size()) return {};
  for (size_t i = 0; i < scheme.size(); ++i) {
    if (std::tolower(static_cast<unsigned char>(url[i])) != scheme[i]) return {};
  }
  const size_t start = scheme.size();
  size_t end = url.find_first_of("/?#", start);
  if (end == std::string::npos) end = url.size();
  std::string host = url.substr(start, end - start);
  if (size_t at = host.rfind('@'); at != std::string::npos) host = host.substr(at + 1);
  if (size_t colon = host.find(':'); colon != std::string::npos) host = host.substr(0, colon);
  for (char& c : host) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
  return host;
}

// Whether a request to `url`, made by a page whose top document is `page_url`,
// gets the headers and brand: every store request, and the Google bar's promo
// API when a store page asks. Nothing else, so other Google pages see cmux's
// own Chromium.
inline bool WebStoreSendsChromeHeaders(const std::string& url, const std::string& page_url) {
  const std::string host = HttpsHost(url);
  if (host == kWebStoreHost) return true;
  return host == kWebStorePromoHost && HttpsHost(page_url) == kWebStoreHost;
}

inline std::string WebStoreCopyright(int year) {
  return "Copyright " + std::to_string(year) + " Manaflow. All rights reserved.";
}

// The major version a brand list or a user agent names for Chromium:
// `"Chromium";v="157"` or `Chrome/157.0.0.0`. Empty when neither is there.
inline std::string ChromiumMajorVersion(const std::string& brands, const std::string& user_agent) {
  auto digits_at = [](const std::string& text, size_t at) {
    size_t end = at;
    while (end < text.size() && std::isdigit(static_cast<unsigned char>(text[end]))) ++end;
    return text.substr(at, end - at);
  };
  const std::string brand = "\"Chromium\";v=\"";
  if (size_t at = brands.find(brand); at != std::string::npos) {
    std::string major = digits_at(brands, at + brand.size());
    if (!major.empty()) return major;
  }
  const std::string token = "Chrome/";
  if (size_t at = user_agent.find(token); at != std::string::npos) return digits_at(user_agent, at + token.size());
  return {};
}

// The sec-ch-ua value cmux sends to the store: the request's own list with
// "Google Chrome" at the same version as Chromium, or `"Chromium";v="N",
// "Google Chrome";v="N"` when the request had none. Unchanged when it already
// names the brand or no version is known (never an invented version).
inline std::string WebStoreBrandList(const std::string& brands, const std::string& user_agent) {
  if (brands.find(std::string("\"") + kWebStoreBrand + "\"") != std::string::npos) return brands;
  const std::string major = ChromiumMajorVersion(brands, user_agent);
  if (major.empty()) return brands;
  const std::string entry = std::string("\"") + kWebStoreBrand + "\";v=\"" + major + "\"";
  if (brands.empty()) return "\"Chromium\";v=\"" + major + "\", " + entry;
  return brands + ", " + entry;
}

}  // namespace cmux_shim
