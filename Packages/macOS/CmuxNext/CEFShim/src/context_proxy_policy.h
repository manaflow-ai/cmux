// The per-context proxy preference: a remote machine's store
// (plans/cmux-next/remote-localhost.md; Cloud browser tabs), where every
// request, loopback included, goes to the app's proxy on 127.0.0.1; and a
// browser profile's own proxy (#24432). No CEF dependency, so
// scripts/cmux-next/test-context-proxy-cpp.sh compiles it alone.
#ifndef CMUX_SHIM_CONTEXT_PROXY_POLICY_H_
#define CMUX_SHIM_CONTEXT_PROXY_POLICY_H_

#include <string>

namespace cmux_shim {

struct ContextProxyValues {
  std::string mode;
  std::string server;
  std::string bypass_list;
  // "webrtc.ip_handling_policy", or empty to leave it as it is.
  std::string webrtc_policy;
};

inline bool ContextProxyPortValid(int port) {
  return port > 0 && port <= 65535;
}

// The "proxy" preference dictionary values for the proxy on `port`.
inline ContextProxyValues ContextProxyFor(int port) {
  return ContextProxyValues{
      "fixed_servers",
      "http://127.0.0.1:" + std::to_string(port),
      // Chromium bypasses loopback by default; "<-loopback>" removes that,
      // so localhost goes to the proxy too. Nothing else bypasses it.
      "<-loopback>",
  };
}

// A profile proxy server the shim accepts: empty (clear), or
// scheme://host:port with scheme http, https or socks5, a host without
// credentials, spaces or separators, and a port 1-65535. One server only:
// no ";" list, so nothing can add a "direct://" fallback.
inline bool ContextProxyServerValid(const std::string& server) {
  if (server.empty()) return true;
  size_t sep = server.find("://");
  if (sep == std::string::npos) return false;
  const std::string scheme = server.substr(0, sep);
  if (scheme != "http" && scheme != "https" && scheme != "socks5") return false;
  const std::string rest = server.substr(sep + 3);
  if (rest.empty()) return false;
  for (char c : rest) {
    if (c == '@' || c == '/' || c == ';' || c == ',' || c == ' ' || c == '\t' || c == '?' || c == '#') return false;
  }
  size_t colon = rest.rfind(':');
  if (colon == std::string::npos || colon == 0 || colon + 1 == rest.size()) return false;
  const std::string host = rest.substr(0, colon);
  if (host.front() == '[' ? host.back() != ']' : host.find(':') != std::string::npos) return false;
  int port = 0;
  for (size_t i = colon + 1; i < rest.size(); ++i) {
    if (rest[i] < '0' || rest[i] > '9' || port > 65535) return false;
    port = port * 10 + (rest[i] - '0');
  }
  return ContextProxyPortValid(port);
}

// A browser profile's proxy (#24432): exactly `server` (fixed_servers, so a
// dead proxy fails closed instead of going direct), the profile's bypass
// list, and WebRTC without UDP outside the proxy. An empty server clears
// it: the system proxy settings and WebRTC's default policy again.
inline ContextProxyValues ContextProxyForServer(const std::string& server, const std::string& bypass_list) {
  if (server.empty()) return ContextProxyValues{"system", "", "", "default"};
  return ContextProxyValues{"fixed_servers", server, bypass_list, "disable_non_proxied_udp"};
}

}  // namespace cmux_shim

#endif  // CMUX_SHIM_CONTEXT_PROXY_POLICY_H_
