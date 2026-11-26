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

// GitHub's return to a cmux console after the person saved a GitHub App installation's settings
// (https://console.cmux.dev/integrations/callback?installation_id=N&setup_action=update, no state, no error). There is
// no connect to finish, and the console's page only says "go back to cmux". In a cmux tab the app takes it instead,
// before it loads (CMUX_SHIM_APP_RETURN_PAGE): it reads GitHub again and the flow's tab closes (#57470). The same rule
// as CloudGitHubCompletion.isSavedOnGitHub, which the host checks again; the hosts are its consoleHosts.
inline bool IsGitHubSavedReturn(const std::string& url) {
  static const char* const kConsoleHosts[] = {"console.cmux.dev", "console-staging.cmux.dev"};
  bool console = false;
  for (const char* host : kConsoleHosts) console = console || IsAuthCallback(url, "", host, "/integrations/callback");
  if (!console) return false;
  size_t scheme_end = url.find("://");
  size_t authority_end = url.find_first_of("/?#", scheme_end + 3);
  if (url.substr(scheme_end + 3, authority_end == std::string::npos ? std::string::npos : authority_end - scheme_end - 3)
          .find('@') != std::string::npos) return false;
  size_t query = url.find('?');
  if (query == std::string::npos) return false;
  std::string params = url.substr(query + 1);
  params = params.substr(0, params.find('#'));
  std::string state, error, setup_action, installation_id;
  bool seen[4] = {false, false, false, false};
  auto first = [&seen](int index, std::string& slot, const std::string& value) {
    if (seen[index]) return;
    seen[index] = true;
    slot = value;
  };
  size_t start = 0;
  while (start <= params.size()) {
    size_t end = params.find('&', start);
    std::string pair = params.substr(start, end == std::string::npos ? std::string::npos : end - start);
    size_t eq = pair.find('=');
    std::string name = pair.substr(0, eq), value = eq == std::string::npos ? "" : pair.substr(eq + 1);
    // The first value counts, as URLComponents' first(where:) does on the host side.
    if (name == "state") first(0, state, value);
    else if (name == "error") first(1, error, value);
    else if (name == "setup_action") first(2, setup_action, value);
    else if (name == "installation_id") first(3, installation_id, value);
    if (end == std::string::npos) break;
    start = end + 1;
  }
  if (!state.empty() || !error.empty() || setup_action != "update") return false;
  if (installation_id.empty() || installation_id.size() > 20) return false;
  for (char c : installation_id) if (c < '0' || c > '9') return false;
  return true;
}

}  // namespace cmux_shim

#endif  // CMUX_SHIM_AUTH_CALLBACK_POLICY_H_
