// cmux-page:// rules that need no CEF (scripts/cmux-next/test-cmux-page-path-cpp.sh
// compiles this header alone): page ids, the fixed MIME table, and the path
// check that keeps every response below the page's resource root.
#ifndef CMUX_SHIM_CMUX_PAGE_PATH_H_
#define CMUX_SHIM_CMUX_PAGE_PATH_H_

#include <limits.h>
#include <stdint.h>
#include <stdlib.h>
#include <sys/stat.h>

#include <string>
#include <utility>
#include <vector>

namespace cmux_shim {

inline constexpr char kCmuxPageScheme[] = "cmux-page";
inline constexpr char kCmuxPageDefaultCSP[] = "default-src 'self'";

// Lowercases `id` into *out when it is a valid page id (the URL host):
// 1-253 characters of [a-z0-9.-], no empty label, no label that starts or
// ends with '-'. Leaves *out empty and returns false otherwise.
inline bool NormalizePageId(const std::string& id, std::string* out) {
  out->clear();
  if (id.empty() || id.size() > 253) return false;
  std::string lower;
  lower.reserve(id.size());
  for (char c : id) {
    if (c >= 'A' && c <= 'Z') c = static_cast<char>(c - 'A' + 'a');
    if (!((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '.' || c == '-')) return false;
    lower.push_back(c);
  }
  size_t start = 0;
  while (true) {
    size_t dot = lower.find('.', start);
    size_t end = dot == std::string::npos ? lower.size() : dot;
    if (end == start || lower[start] == '-' || lower[end - 1] == '-') return false;
    if (dot == std::string::npos) break;
    start = dot + 1;
  }
  *out = lower;
  return true;
}

// Whether a normalized (lowercase) page id is reserved for first-party
// pages: "cmux" and every "cmux." id, the same namespace as PageID.isReserved
// in CmuxNextPages. Only cmux_shim_page_scheme_add_first_party serves them.
inline bool IsReservedPageId(const std::string& lower_id) {
  return lower_id == "cmux" || lower_id.rfind("cmux.", 0) == 0;
}

// The MIME type for the file name's extension, or nullptr: only this
// table is served (lowercase extensions only).
inline const char* PageMimeType(const std::string& path) {
  size_t slash = path.rfind('/');
  size_t dot = path.rfind('.');
  if (dot == std::string::npos || (slash != std::string::npos && dot < slash)) return nullptr;
  const std::string ext = path.substr(dot + 1);
  static const struct {
    const char* ext;
    const char* mime;
  } kTable[] = {
      {"html", "text/html"},       {"js", "text/javascript"}, {"mjs", "text/javascript"},
      {"css", "text/css"},         {"json", "application/json"}, {"svg", "image/svg+xml"},
      {"wasm", "application/wasm"}, {"woff", "font/woff"},    {"woff2", "font/woff2"},
      {"ttf", "font/ttf"},         {"otf", "font/otf"},
  };
  for (const auto& entry : kTable) {
    if (ext == entry.ext) return entry.mime;
  }
  return nullptr;
}

namespace page_detail {

inline int HexValue(char c) {
  if (c >= '0' && c <= '9') return c - '0';
  if (c >= 'a' && c <= 'f') return c - 'a' + 10;
  if (c >= 'A' && c <= 'F') return c - 'A' + 10;
  return -1;
}

// Percent-decodes once. False on a bad or truncated escape or a NUL.
inline bool PercentDecode(const std::string& in, std::string* out) {
  out->clear();
  for (size_t i = 0; i < in.size(); ++i) {
    char c = in[i];
    if (c == '%') {
      if (i + 2 >= in.size()) return false;
      int hi = HexValue(in[i + 1]);
      int lo = HexValue(in[i + 2]);
      if (hi < 0 || lo < 0) return false;
      c = static_cast<char>(hi * 16 + lo);
      i += 2;
    }
    if (c == '\0') return false;
    out->push_back(c);
  }
  return true;
}

inline bool RealPath(const std::string& path, std::string* out) {
  char buffer[PATH_MAX];
  if (!realpath(path.c_str(), buffer)) return false;
  *out = buffer;
  return true;
}

}  // namespace page_detail

// Resolves the URL path of a cmux-page:// request below `root`. On success
// writes the real path of a regular file below the real root and its MIME
// type and returns true. Everything else is a 404 (returns false, leaves
// both outputs empty): a path that is not absolute, a bad escape, a NUL, a
// backslash, a "." or ".." component (also percent-encoded), a missing
// file or a directory, a real path outside the root (symlink escapes;
// compared component-wise, so /root2 is not below /root), or a type
// outside the MIME table. "/" and paths ending in "/" serve index.html.
inline bool ResolvePagePath(const std::string& root, const std::string& url_path, std::string* file,
                            std::string* mime) {
  file->clear();
  mime->clear();
  if (url_path.empty() || url_path[0] != '/') return false;
  std::string decoded;
  if (!page_detail::PercentDecode(url_path, &decoded)) return false;
  if (decoded.find('\\') != std::string::npos) return false;
  std::string relative;
  size_t start = 1;
  while (start <= decoded.size()) {
    size_t slash = decoded.find('/', start);
    std::string part = decoded.substr(start, slash == std::string::npos ? std::string::npos : slash - start);
    if (part == "." || part == "..") return false;
    if (!part.empty()) {
      if (!relative.empty()) relative.push_back('/');
      relative += part;
    }
    if (slash == std::string::npos) break;
    start = slash + 1;
  }
  if (decoded.back() == '/') relative += relative.empty() ? "index.html" : "/index.html";
  std::string real_root;
  if (!page_detail::RealPath(root, &real_root)) return false;
  struct stat root_info;
  if (stat(real_root.c_str(), &root_info) != 0 || !S_ISDIR(root_info.st_mode)) return false;
  std::string real_file;
  if (!page_detail::RealPath(real_root + "/" + relative, &real_file)) return false;
  // Component-wise: the real file must be strictly below the real root.
  const std::string prefix = real_root == "/" ? "/" : real_root + "/";
  if (real_file.size() <= prefix.size() || real_file.compare(0, prefix.size(), prefix) != 0) return false;
  struct stat info;
  if (stat(real_file.c_str(), &info) != 0 || !S_ISREG(info.st_mode)) return false;
  const char* type = PageMimeType(real_file);
  if (!type) return false;
  *file = real_file;
  *mime = type;
  return true;
}

// Whether the URL path of a cmux-page:// request is under one of the page's
// dynamic prefixes (PageDescriptor.dynamicPrefixes): its first non-empty
// component, percent-decoded, is one of them. The page host answers such a
// path (cmux_shim_page_resource_respond); the folder never serves it, also
// when a file of that name exists. A bad escape is not dynamic (a 404).
inline bool IsDynamicPagePath(const std::string& url_path, const std::vector<std::string>& prefixes) {
  if (prefixes.empty()) return false;
  std::string decoded;
  if (!page_detail::PercentDecode(url_path, &decoded)) return false;
  size_t start = 0;
  while (start < decoded.size() && decoded[start] == '/') ++start;
  size_t end = decoded.find('/', start);
  const std::string first = decoded.substr(start, end == std::string::npos ? std::string::npos : end - start);
  if (first.empty()) return false;
  for (const auto& prefix : prefixes) {
    if (first == prefix) return true;
  }
  return false;
}

// Chromium's local network permissions (cef_permission_request_types_t:
// LOCAL_NETWORK_ACCESS 1 << 25, LOCAL_NETWORK 1 << 26, LOOPBACK_NETWORK
// 1 << 27). Numeric, so the rule needs no CEF header.
inline constexpr uint32_t kLocalNetworkPermissions = (1u << 25) | (1u << 26) | (1u << 27);

// Whether Chromium's local network prompt for `requesting_origin` is granted
// at once: a cmux page (cmux-page://cmux.*) reaching its own loopback daemon
// (Home channels' WebSocket). Chromium would ask in a toolbar cmux never
// shows, so the socket waited forever. The page's CSP stays the gate (only a
// first-party page's connect-src names ws://127.0.0.1). Any other origin, or
// any other permission in the request, keeps Chromium's default.
inline bool GrantsCmuxPageLocalNetwork(const std::string& requesting_origin, uint32_t permissions) {
  static const std::string prefix = std::string(kCmuxPageScheme) + "://cmux.";
  if (permissions == 0 || (permissions & ~kLocalNetworkPermissions) != 0) return false;
  return requesting_origin.size() > prefix.size() && requesting_origin.compare(0, prefix.size(), prefix) == 0;
}

// Whether `url` is at `origin` (scheme://host): the origin, then nothing or
// a path, query or fragment.
inline bool UrlHasOrigin(const std::string& url, const std::string& origin) {
  return url.size() >= origin.size() && url.compare(0, origin.size(), origin) == 0 &&
         (url.size() == origin.size() || url[origin.size()] == '/' || url[origin.size()] == '?' ||
          url[origin.size()] == '#');
}

// Whether a request may load a page's files: a main-frame navigation, or a
// request from a frame of the same cmux-page origin (a child frame being
// navigated is judged by its parent). Normal web pages can neither embed
// nor load cmux-page resources.
inline bool PageRequestAllowed(bool main_frame, const std::string& frame_url, const std::string& parent_url,
                               const std::string& domain) {
  if (main_frame) return true;
  const std::string origin = std::string(kCmuxPageScheme) + "://" + domain;
  if (UrlHasOrigin(frame_url, origin)) return true;
  return (frame_url.empty() || frame_url == "about:blank") && UrlHasOrigin(parent_url, origin);
}

// cmux-page://cmux.shared/: the content-hashed chunks every first-party page
// imports (PageSharedChunks in CmuxNextPages). It is never a page: it serves
// only script and style, only to a CORS request from a first-party page
// origin, and never to a navigation.
inline constexpr char kSharedChunkHost[] = "cmux.shared";
// Its policy when the app sends none: nothing it serves may load anything.
inline constexpr char kSharedChunkDefaultCSP[] = "default-src 'none'";

// The Access-Control-Allow-Origin a request with Origin `origin` gets from
// cmux.shared: the origin itself when it is a first-party page origin
// (cmux-page://cmux.<page>, serialized exactly: lowercase, no port, no path),
// else empty (no header, and the request is refused). cmux.shared is not a
// page, so it is not an origin that may read itself. Chrome answers
// chrome://resources the same way (SharedResourcesDataSource::
// GetAccessControlAllowOriginForOrigin, content/browser/webui/
// shared_resources_data_source.cc).
inline std::string SharedChunkAllowedOrigin(const std::string& origin) {
  const std::string prefix = std::string(kCmuxPageScheme) + "://";
  if (origin.size() <= prefix.size() || origin.compare(0, prefix.size(), prefix) != 0) return std::string();
  const std::string host = origin.substr(prefix.size());
  std::string normalized;
  if (!NormalizePageId(host, &normalized) || normalized != host) return std::string();
  if (!IsReservedPageId(host) || host == kSharedChunkHost) return std::string();
  return origin;
}

// Whether a path (a URL path, or the real path a request resolved to) names
// a file type cmux.shared serves: .js or .css (lowercase), so nothing it
// serves can be a document.
inline bool IsSharedChunkPath(const std::string& path) {
  const size_t slash = path.rfind('/');
  const size_t dot = path.rfind('.');
  if (dot == std::string::npos || (slash != std::string::npos && dot < slash)) return false;
  const std::string ext = path.substr(dot + 1);
  return ext == "js" || ext == "css";
}

// Whether cmux.shared answers a request: never a navigation (a main or child
// frame), only one whose Origin is a first-party page origin
// (SharedChunkAllowedOrigin), and, when it comes from a document frame, a
// frame at that origin. A frame with no URL of its own (about:blank,
// about:srcdoc) or no frame (a worker) is judged by the Origin alone.
inline bool SharedChunkRequestAllowed(bool navigation, const std::string& frame_url, const std::string& origin) {
  if (navigation || SharedChunkAllowedOrigin(origin).empty()) return false;
  if (frame_url.empty() || frame_url == "about:blank" || frame_url == "about:srcdoc") return true;
  return UrlHasOrigin(frame_url, origin);
}

// Response headers of every cmux.shared response. `allowed_origin` empty
// sends no Access-Control-Allow-Origin. Vary: Origin as Chrome sends with
// its ACAO (URLDataManagerBackend, content/browser/webui/
// url_data_manager_backend.cc). frame-ancestors 'none' is added unless the
// CSP sets its own.
inline std::vector<std::pair<std::string, std::string>> SharedChunkResponseHeaders(const std::string& csp,
                                                                                   const std::string& allowed_origin) {
  std::string policy = csp;
  if (policy.find("frame-ancestors") == std::string::npos) policy += "; frame-ancestors 'none'";
  std::vector<std::pair<std::string, std::string>> headers = {
      {"Content-Security-Policy", policy},
      {"X-Content-Type-Options", "nosniff"},
      {"X-Frame-Options", "DENY"},
      {"Cross-Origin-Resource-Policy", "same-origin"},
      {"Vary", "Origin"},
  };
  if (!allowed_origin.empty()) headers.emplace_back("Access-Control-Allow-Origin", allowed_origin);
  return headers;
}

// Response headers of every cmux-page response. frame-ancestors 'self' is
// added unless the page's CSP sets its own.
inline std::vector<std::pair<std::string, std::string>> PageResponseHeaders(const std::string& csp) {
  std::string policy = csp;
  if (policy.find("frame-ancestors") == std::string::npos) policy += "; frame-ancestors 'self'";
  return {
      {"Content-Security-Policy", policy},
      {"X-Content-Type-Options", "nosniff"},
      {"X-Frame-Options", "SAMEORIGIN"},
      {"Cross-Origin-Resource-Policy", "same-origin"},
  };
}

}  // namespace cmux_shim

#endif  // CMUX_SHIM_CMUX_PAGE_PATH_H_
