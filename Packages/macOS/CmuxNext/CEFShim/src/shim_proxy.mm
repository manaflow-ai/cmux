// Remote localhost (plans/cmux-next/remote-localhost.md): per request
// context proxy configuration, proxy credentials for the app's in-process
// proxy, and the main-frame navigation guard that keeps loopback origins of a
// remote machine in their own store.

#include <arpa/inet.h>

#include <algorithm>
#include <cctype>
#include <mutex>

#include "agent_url_policy.h"
#include "auth_callback_policy.h"
#include "context_proxy_policy.h"
#include "include/cef_parser.h"
#include "shim_internal.h"

namespace cmux_shim {

namespace {

struct ContextProxy {
  // A remote machine's store: the app's proxy on this port.
  int port = 0;
  // Else a browser profile's own proxy (#24432): `server` empty clears it.
  bool profile = false;
  std::string server;
  std::string bypass_list;
  // 0 none, 1 pending, 2 applied, -1 failed.
  int state = 0;
};

// Written on the UI thread; read from the host's calls (UI thread).
std::mutex& proxy_mutex() {
  static std::mutex mutex;
  return mutex;
}

std::map<std::string, ContextProxy>& proxies() {
  static std::map<std::string, ContextProxy> map;
  return map;
}

std::map<int, int>& guards() {
  static std::map<int, int> map;
  return map;
}

struct AuthCallback {
  std::string scheme;
  std::string host;
  std::string path;
};

// UI thread only (set by the host, read in OnBeforeBrowse).
std::map<int, AuthCallback>& auth_callbacks() {
  static std::map<int, AuthCallback> map;
  return map;
}

bool StrictIPv4Loopback(const std::string& host) {
  int parts = 0;
  size_t start = 0;
  int first = -1;
  while (start <= host.size()) {
    size_t dot = host.find('.', start);
    std::string part = host.substr(start, dot == std::string::npos ? std::string::npos : dot - start);
    if (part.empty() || part.size() > 3 || (part.size() > 1 && part[0] == '0')) return false;
    for (char c : part) {
      if (!std::isdigit(static_cast<unsigned char>(c))) return false;
    }
    int value = std::stoi(part);
    if (value > 255) return false;
    if (parts == 0) first = value;
    ++parts;
    if (dot == std::string::npos) break;
    start = dot + 1;
  }
  return parts == 4 && first == 127;
}

bool IPv6Loopback(const std::string& host) {
  in6_addr address{};
  if (inet_pton(AF_INET6, host.c_str(), &address) != 1) return false;
  if (IN6_IS_ADDR_LOOPBACK(&address)) return true;
  // IPv4-mapped 127/8.
  return IN6_IS_ADDR_V4MAPPED(&address) && address.s6_addr[12] == 127;
}

bool LocalhostName(std::string name) {
  std::transform(name.begin(), name.end(), name.begin(), [](unsigned char c) { return std::tolower(c); });
  if (!name.empty() && name.back() == '.') name.pop_back();
  if (name.empty() || name.size() > 253) return false;
  size_t start = 0;
  std::string last;
  while (true) {
    size_t dot = name.find('.', start);
    std::string label = name.substr(start, dot == std::string::npos ? std::string::npos : dot - start);
    if (label.empty() || label.size() > 63 || label.front() == '-' || label.back() == '-') return false;
    for (char c : label) {
      if (!(std::isalnum(static_cast<unsigned char>(c)) || c == '-')) return false;
    }
    last = label;
    if (dot == std::string::npos) break;
    start = dot + 1;
  }
  return last == "localhost";
}

}  // namespace

// The same literal rule as LoopbackHost (Swift) and the daemon.
bool IsLoopbackHost(const std::string& raw) {
  if (raw.empty()) return false;
  std::string host = raw;
  if (host.front() == '[') {
    if (host.back() != ']') return false;
    return IPv6Loopback(host.substr(1, host.size() - 2));
  }
  if (host.find(':') != std::string::npos) return IPv6Loopback(host);
  if (std::all_of(host.begin(), host.end(), [](char c) { return std::isdigit(static_cast<unsigned char>(c)) || c == '.'; })) {
    return StrictIPv4Loopback(host);
  }
  return LocalhostName(host);
}

// Whether a main-frame URL is a web URL (http, https) and loopback.
static bool WebURL(const std::string& url, bool* loopback, std::string* host_out = nullptr) {
  CefURLParts parts;
  if (!CefParseURL(url, parts)) return false;
  std::string scheme = CefString(&parts.scheme).ToString();
  if (scheme != "http" && scheme != "https") return false;
  std::string host = CefString(&parts.host).ToString();
  *loopback = IsLoopbackHost(host);
  if (host_out) *host_out = host;
  return true;
}

// An Open Desktop page: a host under `.cloud-desktop.localhost`
// (RemoteLocalhostService.desktopHostSuffix), which only the machine's own store reaches.
static bool IsCloudDesktopHost(std::string host) {
  std::transform(host.begin(), host.end(), host.begin(), [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
  if (!host.empty() && host.back() == '.') host.pop_back();
  static const std::string suffix = ".cloud-desktop.localhost";
  return host.size() > suffix.size() && host.compare(host.size() - suffix.size(), suffix.size(), suffix) == 0;
}

constexpr int kStoreGuardMask = 3;
constexpr int kAgentGuardBit = 4;

bool NavigationViolatesGuard(int browser_id, const std::string& url) {
  auto it = guards().find(browser_id);
  if (it == guards().end()) return false;
  int store = it->second & kStoreGuardMask;
  if (store == 0) return false;
  bool loopback = false;
  std::string host;
  // Non-web URLs (about:blank, data:, chrome://) never switch stores.
  if (!WebURL(url, &loopback, &host)) return false;
  // 3: any URL but an Open Desktop page, which goes to its machine's store, never this Mac.
  if (store == 3) return IsCloudDesktopHost(host);
  return store == 1 ? !loopback : loopback;
}

bool BrowserIsAgentDriven(int browser_id) {
  auto it = guards().find(browser_id);
  return it != guards().end() && (it->second & kAgentGuardBit) != 0;
}

bool NavigationRefusedForAgent(int browser_id, const std::string& url) {
  auto it = guards().find(browser_id);
  if (it == guards().end() || (it->second & kAgentGuardBit) == 0) return false;
  return AgentRefusesURL(url);
}

void ForgetNavigationGuard(int browser_id) {
  guards().erase(browser_id);
  auth_callbacks().erase(browser_id);
}

bool NavigationIsAuthCallback(int browser_id, const std::string& url) {
  auto it = auth_callbacks().find(browser_id);
  if (it == auth_callbacks().end()) return false;
  return IsAuthCallback(url, it->second.scheme, it->second.host, it->second.path);
}

// UI thread: applies the proxy of `cache_path` to its request context.
void ApplyContextProxy(CefRefPtr<CefRequestContext> context, const std::string& cache_path) {
  ContextProxyValues values;
  {
    std::lock_guard<std::mutex> lock(proxy_mutex());
    auto it = proxies().find(cache_path);
    if (it == proxies().end()) return;
    values = it->second.profile ? ContextProxyForServer(it->second.server, it->second.bypass_list)
                                : ContextProxyFor(it->second.port);
  }
  CefRefPtr<CefDictionaryValue> dict = CefDictionaryValue::Create();
  dict->SetString("mode", values.mode);
  if (!values.server.empty()) dict->SetString("server", values.server);
  if (!values.bypass_list.empty()) dict->SetString("bypass_list", values.bypass_list);
  CefRefPtr<CefValue> value = CefValue::Create();
  value->SetDictionary(dict);
  CefString error;
  bool ok = context->SetPreference("proxy", value, error);
  if (ok && !values.webrtc_policy.empty() && context->CanSetPreference("webrtc.ip_handling_policy")) {
    CefRefPtr<CefValue> policy = CefValue::Create();
    policy->SetString(values.webrtc_policy);
    CefString webrtc_error;
    // Leak policy: a proxied profile must not send WebRTC UDP around the proxy.
    ok = context->SetPreference("webrtc.ip_handling_policy", policy, webrtc_error);
  }
  std::lock_guard<std::mutex> lock(proxy_mutex());
  auto it = proxies().find(cache_path);
  if (it != proxies().end()) it->second.state = ok ? 2 : -1;
}

void ForgetContextProxy(const std::string& key) {
  std::lock_guard<std::mutex> lock(proxy_mutex());
  proxies().erase(key);
}

}  // namespace cmux_shim

using namespace cmux_shim;

extern "C" {

int cmux_shim_set_context_proxy(const char* profile_cache_path, int port) {
  if (!profile_cache_path || !*profile_cache_path || !ContextProxyPortValid(port)) return 0;
  std::string path = profile_cache_path;
  {
    std::lock_guard<std::mutex> lock(proxy_mutex());
    ContextProxy& proxy = proxies()[path];
    proxy.port = port;
    proxy.state = 1;
  }
  // A context created earlier this launch gets it now; a new one gets it
  // in OnRequestContextInitialized.
  if (CefRefPtr<CefRequestContext> context = ExistingRequestContext(path)) {
    ApplyContextProxy(context, path);
  }
  return 1;
}

int cmux_shim_set_context_proxy_server(const char* profile_cache_path, const char* server, const char* bypass_list) {
  if (!profile_cache_path || !*profile_cache_path) return 0;
  const std::string value = server ? server : "";
  const std::string bypass = bypass_list ? bypass_list : "";
  if (!ContextProxyServerValid(value) || bypass.find_first_of("\r\n") != std::string::npos) return 0;
  std::string path = profile_cache_path;
  {
    std::lock_guard<std::mutex> lock(proxy_mutex());
    ContextProxy& proxy = proxies()[path];
    // A remote machine's store keeps its own proxy.
    if (proxy.port != 0 && !proxy.profile) return 0;
    proxy.profile = true;
    proxy.server = value;
    proxy.bypass_list = bypass;
    proxy.state = 1;
  }
  if (CefRefPtr<CefRequestContext> context = ExistingRequestContext(path)) {
    ApplyContextProxy(context, path);
  }
  return 1;
}

void cmux_shim_release_context(const char* profile_cache_path) {
  if (!profile_cache_path || !*profile_cache_path) return;
  ReleaseRequestContext(profile_cache_path);
}

int cmux_shim_context_proxy_state(const char* profile_cache_path) {
  if (!profile_cache_path) return 0;
  std::lock_guard<std::mutex> lock(proxy_mutex());
  auto it = proxies().find(profile_cache_path);
  return it == proxies().end() ? 0 : it->second.state;
}

void cmux_shim_set_auth_callback(int browser_id, const char* scheme, const char* https_host, const char* https_path) {
  std::string s = scheme ? scheme : "", host = https_host ? https_host : "", path = https_path ? https_path : "";
  if (s.empty() && host.empty()) {
    auth_callbacks().erase(browser_id);
  } else {
    auth_callbacks()[browser_id] = AuthCallback{s, host, path};
  }
}

void cmux_shim_set_navigation_guard(int browser_id, int mode) {
  if (mode == 0) {
    guards().erase(browser_id);
  } else {
    guards()[browser_id] = mode;
  }
}

}  // extern "C"
