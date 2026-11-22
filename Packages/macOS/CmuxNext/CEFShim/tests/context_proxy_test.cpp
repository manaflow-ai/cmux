// Checks the per-profile proxy preference the shim gives a remote machine's
// store (CEFShim/src/context_proxy_policy.h): every request goes to the
// app's proxy on 127.0.0.1, and Chromium's implicit loopback bypass is
// removed ("<-loopback>"), so a proxied tab never reaches this Mac's
// localhost. scripts/cmux-next/test-context-proxy-cpp.sh compiles it alone.
#include <iostream>
#include <string>

#include "../src/context_proxy_policy.h"

static int g_cases = 0;
static int g_failures = 0;

static void Expect(bool ok, const std::string& what) {
  ++g_cases;
  if (!ok) {
    ++g_failures;
    std::cerr << "FAIL " << what << "\n";
  }
}

int main() {
  for (int port : {1, 3000, 49153, 65535}) {
    cmux_shim::ContextProxyValues values = cmux_shim::ContextProxyFor(port);
    const std::string at = " (port " + std::to_string(port) + ")";
    Expect(values.mode == "fixed_servers", "mode is fixed_servers" + at + ": " + values.mode);
    Expect(values.server == "http://127.0.0.1:" + std::to_string(port), "server is http://127.0.0.1:<port>" + at + ": " + values.server);
    // Exactly "<-loopback>": nothing bypasses the proxy, loopback included.
    Expect(values.bypass_list == "<-loopback>", "bypass_list is exactly <-loopback>" + at + ": " + values.bypass_list);
    Expect(cmux_shim::ContextProxyPortValid(port), "port valid" + at);
  }
  for (int port : {0, -1, 65536, 100000}) {
    Expect(!cmux_shim::ContextProxyPortValid(port), "port refused: " + std::to_string(port));
  }
  std::cout << g_cases << " cases, " << g_failures << " failures\n";
  return g_failures == 0 && g_cases > 0 ? 0 : 1;
}
