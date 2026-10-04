// Remote localhost (plans/cmux-next/remote-localhost.md): per request
// context proxy configuration, proxy credentials for the app's in-process
// proxy, and the main-frame navigation guard that keeps loopback origins of a
// remote machine in their own store.

#include <arpa/inet.h>

#include <algorithm>
#include <cctype>
#include <mutex>

#include "include/cef_parser.h"
#include "shim_internal.h"

namespace cmux_shim {

namespace {

struct ContextProxy {
  int port = 0;
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
static bool WebURL(const std::string& url, bool* loopback) {
  CefURLParts parts;
  if (!CefParseURL(url, parts)) return false;
  std::string scheme = CefString(&parts.scheme).ToString();
  if (scheme != "http" && scheme != "https") return false;
  *loopback = IsLoopbackHost(CefString(&parts.host).ToString());
  return true;
}

constexpr int kStoreGuardMask = 3;
constexpr int kAgentGuardBit = 4;

bool NavigationViolatesGuard(int browser_id, const std::string& url) {
  auto it = guards().find(browser_id);
  if (it == guards().end()) return false;
  int store = it->second & kStoreGuardMask;
  if (store == 0) return false;
  bool loopback = false;
  // Non-web URLs (about:blank, data:, chrome://) never switch stores.
  if (!WebURL(url, &loopback)) return false;
  return store == 1 ? !loopback : loopback;
}

// AgentURLPolicy.swift in C++: keep the two in step.
static bool AgentRefusesURL(std::string text, int depth = 0) {
  if (depth > 2) return true;
  text.erase(std::remove_if(text.begin(), text.end(), [](char c) { return c == '\t' || c == '\n' || c == '\r'; }),
             text.end());
  size_t start = 0;
  while (start < text.size() && static_cast<unsigned char>(text[start]) <= 0x20) ++start;
  size_t colon = text.find(':', start);
  if (colon == std::string::npos || colon == start) return false;
  std::string scheme = text.substr(start, colon - start);
  if (!std::isalpha(static_cast<unsigned char>(scheme[0]))) return false;
  for (char& c : scheme) {
    unsigned char u = static_cast<unsigned char>(c);
    if (!std::isalnum(u) && c != '+' && c != '-' && c != '.') return false;
    c = static_cast<char>(std::tolower(u));
  }
  static const char* const kRefused[] = {"chrome", "chrome-extension", "chrome-untrusted", "chrome-search",
                                         "devtools", "chrome-devtools", "view-source"};
  for (const char* refused : kRefused) {
    if (scheme == refused) return true;
  }
  std::string rest = text.substr(colon + 1);
  if (scheme == "blob" || scheme == "filesystem") return AgentRefusesURL(rest, depth + 1);
  if (scheme == "about") {
    std::string page = rest.substr(0, rest.find_first_of("?#"));
    for (char& c : page) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
    return page != "blank" && page != "srcdoc";
  }
  return false;
}

bool NavigationRefusedForAgent(int browser_id, const std::string& url) {
  auto it = guards().find(browser_id);
  if (it == guards().end() || (it->second & kAgentGuardBit) == 0) return false;
  return AgentRefusesURL(url);
}

void ForgetNavigationGuard(int browser_id) {
  guards().erase(browser_id);
}

// UI thread: applies the proxy of `cache_path` to its request context.
void ApplyContextProxy(CefRefPtr<CefRequestContext> context, const std::string& cache_path) {
  int port = 0;
  {
    std::lock_guard<std::mutex> lock(proxy_mutex());
    auto it = proxies().find(cache_path);
    if (it == proxies().end()) return;
    port = it->second.port;
  }
  CefRefPtr<CefDictionaryValue> dict = CefDictionaryValue::Create();
  dict->SetString("mode", "fixed_servers");
  dict->SetString("server", "http://127.0.0.1:" + std::to_string(port));
  // Chromium bypasses loopback by default; "<-loopback>" removes that, so
  // localhost goes to the proxy too. Nothing else bypasses it.
  dict->SetString("bypass_list", "<-loopback>");
  CefRefPtr<CefValue> value = CefValue::Create();
  value->SetDictionary(dict);
  CefString error;
  bool ok = context->SetPreference("proxy", value, error);
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
  if (!profile_cache_path || !*profile_cache_path || port <= 0 || port > 65535) return 0;
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

void cmux_shim_set_navigation_guard(int browser_id, int mode) {
  if (mode == 0) {
    guards().erase(browser_id);
  } else {
    guards()[browser_id] = mode;
  }
}

}  // extern "C"
