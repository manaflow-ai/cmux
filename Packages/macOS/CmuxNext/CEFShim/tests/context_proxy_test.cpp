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
  // #24432: a browser profile's own proxy. One fixed server and nothing
  // else, so a dead proxy fails closed (Chromium never falls back to
  // direct); WebRTC sends no UDP outside the proxy. Loopback keeps
  // Chromium's default bypass unless the profile's list says otherwise.
  {
    cmux_shim::ContextProxyValues values = cmux_shim::ContextProxyForServer("socks5://127.0.0.1:1080", "");
    Expect(values.mode == "fixed_servers", "profile proxy mode: " + values.mode);
    Expect(values.server == "socks5://127.0.0.1:1080", "profile proxy server: " + values.server);
    Expect(values.bypass_list.empty(), "profile proxy bypass: " + values.bypass_list);
    Expect(values.webrtc_policy == "disable_non_proxied_udp", "profile proxy WebRTC: " + values.webrtc_policy);
    cmux_shim::ContextProxyValues bypass = cmux_shim::ContextProxyForServer("http://gw.test:8080", "*.corp.test;10.0.0.0/8");
    Expect(bypass.bypass_list == "*.corp.test;10.0.0.0/8", "profile bypass kept: " + bypass.bypass_list);
  }
  {
    // Cleared: the system proxy settings again, WebRTC as default.
    cmux_shim::ContextProxyValues values = cmux_shim::ContextProxyForServer("", "");
    Expect(values.mode == "system", "cleared mode: " + values.mode);
    Expect(values.server.empty(), "cleared server: " + values.server);
    Expect(values.webrtc_policy == "default", "cleared WebRTC: " + values.webrtc_policy);
  }
  for (const char* good : {"http://gw.test:8080", "https://gw.test:443", "socks5://127.0.0.1:1080", "http://[::1]:3128", ""}) {
    Expect(cmux_shim::ContextProxyServerValid(good), std::string("server valid: ") + good);
  }
  for (const char* bad : {"gw.test:8080", "ftp://gw.test:21", "http://me:pw@gw.test:8080", "http://gw.test", "http://gw.test:0",
                          "http://gw.test:99999", "socks5://a b:1", "http://gw.test:80;direct://"}) {
    Expect(!cmux_shim::ContextProxyServerValid(bad), std::string("server refused: ") + bad);
  }
  std::cout << g_cases << " cases, " << g_failures << " failures\n";
  return g_failures == 0 && g_cases > 0 ? 0 : 1;
}
