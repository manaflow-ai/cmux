// Which main-frame navigation of a sign-in tab ends its session
// (ASWebAuthenticationSession, cmux as the default browser). The host sets
// the session's callback per tab (cmux_shim_set_auth_callback): a custom
// scheme, or an https host and path. A matching navigation is cancelled
// before it loads and reported as AUTH_CALLBACK, so the callback URL (which
// carries the code) never reaches the network or another app. The host checks
// it again with the system's own matcher. The same rule as the system's:
// scheme and host compare without case, the path ignores one trailing slash,
// query and fragment do not count. No CEF dependency, so the test compiles it
// alone (scripts/cmux-next/test-auth-callback-policy-cpp.sh).
#ifndef CMUX_SHIM_AUTH_CALLBACK_POLICY_H_
#define CMUX_SHIM_AUTH_CALLBACK_POLICY_H_

#include <cctype>
#include <string>

namespace cmux_shim {

inline std::string AuthLower(std::string text) {
  for (char& c : text) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
  return text;
}

// True when `url` is the session's callback: `scheme` (a custom scheme), or
// https://`host``path`. An empty scheme and host match nothing.
inline bool IsAuthCallback(std::string url, const std::string& scheme, const std::string& host,
                           const std::string& path) {
  size_t start = 0;
  while (start < url.size() && static_cast<unsigned char>(url[start]) <= 0x20) ++start;
  url = url.substr(start);
  size_t colon = url.find(':');
  if (colon == std::string::npos || colon == 0) return false;
  std::string url_scheme = AuthLower(url.substr(0, colon));
  if (!scheme.empty()) return url_scheme == AuthLower(scheme);
  if (host.empty() || url_scheme != "https" || url.compare(colon, 3, "://") != 0) return false;
  std::string rest = url.substr(colon + 3);
  size_t authority_end = rest.find_first_of("/?#");
  std::string authority = rest.substr(0, authority_end);
  std::string tail = authority_end == std::string::npos ? "" : rest.substr(authority_end);
  size_t at = authority.rfind('@');
  if (at != std::string::npos) authority = authority.substr(at + 1);
  size_t port = authority.rfind(':');
  if (port != std::string::npos && authority.find(']') == std::string::npos) {
    if (authority.substr(port + 1) != "443" && port + 1 != authority.size()) return false;
    authority = authority.substr(0, port);
  }
  std::string url_host = AuthLower(authority);
  while (!url_host.empty() && url_host.back() == '.') url_host.pop_back();
  std::string want_host = AuthLower(host);
  while (!want_host.empty() && want_host.back() == '.') want_host.pop_back();
  if (url_host != want_host) return false;
  std::string url_path = tail.substr(0, tail.find_first_of("?#"));
  if (url_path.empty()) url_path = "/";
  std::string want_path = path.empty() ? "/" : path;
  auto trim = [](std::string p) {
    if (p.size() > 1 && p.back() == '/') p.pop_back();
    return p;
  };
  return trim(url_path) == trim(want_path);
}

}  // namespace cmux_shim

#endif  // CMUX_SHIM_AUTH_CALLBACK_POLICY_H_
