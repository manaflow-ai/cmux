// The per-profile proxy preference of a remote machine's store
// (plans/cmux-next/remote-localhost.md; Cloud browser tabs): every request,
// loopback included, goes to the app's proxy on 127.0.0.1. No CEF
// dependency, so scripts/cmux-next/test-context-proxy-cpp.sh compiles it alone.
#ifndef CMUX_SHIM_CONTEXT_PROXY_POLICY_H_
#define CMUX_SHIM_CONTEXT_PROXY_POLICY_H_

#include <string>

namespace cmux_shim {

struct ContextProxyValues {
  std::string mode;
  std::string server;
  std::string bypass_list;
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

}  // namespace cmux_shim

#endif  // CMUX_SHIM_CONTEXT_PROXY_POLICY_H_
