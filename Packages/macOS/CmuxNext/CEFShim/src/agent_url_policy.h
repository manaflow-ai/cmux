// The agent URL rule in C++ (plans/cmux-next/passwords.md, section 2): the
// same rule as AgentURLPolicy.swift and the Rust cmux-browser-host
// policy::is_browser_page. All three pass schemas/agent-url-policy/vectors.json
// (scripts/cmux-next/test-agent-url-policy-cpp.sh). No CEF dependency, so the
// test compiles it alone.
#ifndef CMUX_SHIM_AGENT_URL_POLICY_H_
#define CMUX_SHIM_AGENT_URL_POLICY_H_

#include <algorithm>
#include <cctype>
#include <string>

namespace cmux_shim {

// More nested blob:/filesystem: wrappers than this are refused (fail closed).
constexpr int kAgentURLMaxWrapperDepth = 2;

// First-party pages (cmux-page://cmux, cmux-page://cmux.<id>) are refused;
// third-party app pages stay allowed. Fail closed on an empty host or a
// percent escape.
inline bool IsReservedPageHost(const std::string& rest) {
  size_t start = rest.find_first_not_of("/\\");
  if (start == std::string::npos) return true;
  size_t end = rest.find_first_of("/\\?#", start);
  std::string host = rest.substr(start, end == std::string::npos ? std::string::npos : end - start);
  if (host.find('%') != std::string::npos) return true;
  size_t at = host.rfind('@');
  if (at != std::string::npos) host = host.substr(at + 1);
  size_t port = host.find(':');
  if (port != std::string::npos) host = host.substr(0, port);
  for (char& c : host) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
  while (!host.empty() && host.back() == '.') host.pop_back();
  return host.empty() || host == "cmux" || host.rfind("cmux.", 0) == 0;
}

// True when an agent-driven tab must not load `text`: the schemes chrome,
// chrome-extension, chrome-untrusted, chrome-search, devtools,
// chrome-devtools, view-source and cmux; reserved cmux-page hosts; about:
// other than blank and srcdoc; blob: and filesystem: of those. Tabs, CR and LF are dropped and leading
// bytes <= 0x20 trimmed, as Chromium does.
inline bool AgentRefusesURL(std::string text, int wrappers = 0) {
  if (wrappers > kAgentURLMaxWrapperDepth) return true;
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
                                         "devtools", "chrome-devtools", "view-source", "cmux"};
  for (const char* refused : kRefused) {
    if (scheme == refused) return true;
  }
  std::string rest = text.substr(colon + 1);
  if (scheme == "cmux-page") return IsReservedPageHost(rest);
  if (scheme == "blob" || scheme == "filesystem") return AgentRefusesURL(rest, wrappers + 1);
  if (scheme == "about") {
    std::string page = rest.substr(0, rest.find_first_of("?#"));
    for (char& c : page) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
    return page != "blank" && page != "srcdoc";
  }
  return false;
}

}  // namespace cmux_shim

#endif  // CMUX_SHIM_AGENT_URL_POLICY_H_
