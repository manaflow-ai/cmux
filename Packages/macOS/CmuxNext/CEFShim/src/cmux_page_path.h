// cmux-page:// rules that need no CEF (scripts/cmux-next/test-cmux-page-path-cpp.sh
// compiles this header alone): page ids, the fixed MIME table, and the path
// check that keeps every response below the page's resource root.
#ifndef CMUX_SHIM_CMUX_PAGE_PATH_H_
#define CMUX_SHIM_CMUX_PAGE_PATH_H_

#include <ctype.h>
#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/stat.h>

#include <string>
#include <utility>
#include <vector>

#include "artifact_page.h"

namespace cmux_shim {

inline constexpr char kCmuxPageScheme[] = "cmux-page";
inline constexpr char kCmuxPageDefaultCSP[] = "default-src 'self'";

// The CefSchemeRegistrar::AddCustomScheme options of cmux-page://, as plain bits so the
// test compiles with no CEF (page_scheme_registration.h checks each against CEF's
// cef_scheme_options_t). Standard (the host is the origin), secure, CORS and fetch() within
// the scheme, and V8's code cache: the fork's CMUX_CEF_SCHEME_OPTION_CODE_CACHE (include/
// cef_cmux.h, manaflow-ai/cef) puts the scheme in Chromium's
// ContentClient::Schemes::code_cache_schemes, as chrome:// WebUI scripts are, so pane.js
// keeps its compiled code in the profile's Code Cache folder across launches. Blink checks
// that cache against the script's source hash (code cache with hashing), so a changed
// pane.js, after an app update or a web update, compiles again and never runs an old
// compile. Chromium allows it only beside the standard bit. A fork without it ignores the bit.
namespace page_scheme_option {
inline constexpr int kStandard = 1 << 0;
inline constexpr int kSecure = 1 << 3;
inline constexpr int kCorsEnabled = 1 << 4;
inline constexpr int kFetchEnabled = 1 << 6;
inline constexpr int kCodeCache = 1 << 7;
}  // namespace page_scheme_option

inline constexpr int kCmuxPageSchemeOptions = page_scheme_option::kStandard | page_scheme_option::kSecure |
                                              page_scheme_option::kCorsEnabled | page_scheme_option::kFetchEnabled |
                                              page_scheme_option::kCodeCache;

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

// The real path of the regular file `url_path` names below `root`, with `suffix` added to its last
// component (empty for the file itself; ResolvePackedPagePath, cmux_page_packed.h, asks for its
// packed copy), by ResolvePagePath's rules except the MIME table. False for anything else.
inline bool ResolvePageFile(const std::string& root, const std::string& url_path, const std::string& suffix,
                            std::string* file) {
  file->clear();
  if (url_path.empty() || url_path[0] != '/') return false;
  std::string decoded;
  if (!PercentDecode(url_path, &decoded)) return false;
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
  relative += suffix;
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
  *file = real_file;
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
  std::string real_file;
  if (!page_detail::ResolvePageFile(root, url_path, "", &real_file)) return false;
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

// Whether `url` is a document or file of the cmux page `domain` (cmux-page://<domain>, then
// end, '/', '?' or '#').
inline bool SameCmuxPageOrigin(const std::string& url, const std::string& domain) {
  const std::string origin = std::string(kCmuxPageScheme) + "://" + domain;
  return url.size() >= origin.size() && url.compare(0, origin.size(), origin) == 0 &&
         (url.size() == origin.size() || url[origin.size()] == '/' || url[origin.size()] == '?' ||
          url[origin.size()] == '#');
}

// What the page scheme does with a request for a page's files.
enum class PageRequestVerdict {
  kAllow,
  kRefuse,
  // The requesting frame is a top frame the browser side still reads as empty or about:blank:
  // its document has committed in the renderer, but CEF updates the frame's URL on the UI
  // thread, after that document's own files are already asked for on the IO thread. The
  // request waits until the browser knows the frame's URL (`frame_settled`), then is judged.
  kWaitForFrame,
};

// Whether a request may load a page's files: a main-frame navigation, or a
// request from a frame of the same cmux-page origin (a child frame being
// navigated is judged by its parent). Normal web pages can neither embed
// nor load cmux-page resources. `frame_settled` is false while the browser
// side may not have the requesting frame's committed URL yet; a blank top
// frame then waits instead of being refused (on a busy first launch every
// script and style of a page was refused, and the page stayed blank). A
// frame that stays blank is refused once settled, as before.
inline PageRequestVerdict JudgePageRequest(bool main_frame, const std::string& frame_url, const std::string& parent_url,
                                           const std::string& domain, bool frame_settled) {
  if (main_frame) return PageRequestVerdict::kAllow;
  if (ArtifactContextRestricted(frame_url, parent_url)) return PageRequestVerdict::kRefuse;
  auto same = [&](const std::string& url) { return SameCmuxPageOrigin(url, domain); };
  if (same(frame_url)) return PageRequestVerdict::kAllow;
  if (!frame_url.empty() && frame_url != "about:blank") return PageRequestVerdict::kRefuse;
  if (!parent_url.empty()) return same(parent_url) ? PageRequestVerdict::kAllow : PageRequestVerdict::kRefuse;
  return frame_settled ? PageRequestVerdict::kRefuse : PageRequestVerdict::kWaitForFrame;
}

// A request that waited (kWaitForFrame), judged once the browser has the URL of its top frame
// (`settled_url`): that frame must be the page's own document, and the request's own first party
// (the top document that asked) must be the page too, so a document that replaces the page in
// the same browser before the browser has seen it commit cannot load the page's files.
inline bool DeferredPageRequestAllowed(const std::string& settled_url, const std::string& first_party,
                                       const std::string& domain) {
  return JudgePageRequest(false, settled_url, "", domain, true) == PageRequestVerdict::kAllow &&
         SameCmuxPageOrigin(first_party, domain);
}

// JudgePageRequest once the frame is settled: allowed or not.
inline bool PageRequestAllowed(bool main_frame, const std::string& frame_url, const std::string& parent_url,
                               const std::string& domain) {
  return JudgePageRequest(main_frame, frame_url, parent_url, domain, true) == PageRequestVerdict::kAllow;
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

// The agent chat page (`cmux.agent`) the person types in: its renderer is its own.
//
// Every agent chat is the same site, and the fork runs one renderer per site for cmux pages
// (`cmux-process-per-site-schemes`), so a key typed in one chat waited on that renderer's main
// thread behind every other chat's stream work (key to the page's listener p95 31-37 ms on
// cmux20-bench while the app's main thread was mostly idle). Chromium keys that one renderer by the
// whole SiteInfo, which includes the document's cross-origin isolation (WebExposedIsolationInfo): a
// document answered with `Cross-Origin-Opener-Policy: same-origin` and
// `Cross-Origin-Embedder-Policy: credentialless` is cross-origin isolated, so it goes to the site's
// isolated renderer, one more renderer whatever number of documents land there, while documents
// without them keep sharing. Same origin, so localStorage and BroadcastChannel stay shared.
//
// Never `Origin-Agent-Cluster: ?1` here: Chromium honors that opt-in only for HTTP(S) origins, yet
// still registers it for a cmux-page document, and ChildProcessSecurityPolicy CHECKs ("Trying to
// isolate invalid origin") in the browser process: the app died on the first chat opened so. COOP
// alone isolates nothing (the new browsing context group finds the same SiteInfo's renderer).
//
// An isolated document may embed only frames and workers that answer with a COEP of their own, so
// every other `cmux.agent` response (the page's module workers, its `__artifact` frame) carries
// `Cross-Origin-Embedder-Policy: credentialless`; for a shared chat that only keeps those workers'
// own cross-origin no-cors requests uncredentialed. A top document of another chat gets nothing.
//
// `owner_browser_id` is the browser the app names (cmux_shim_page_own_renderer): the most recently
// focused agent chat.
inline constexpr char kOwnRendererPageId[] = "cmux.agent";
inline constexpr char kOwnRendererEmbedderPolicy[] = "credentialless";

inline std::vector<std::pair<std::string, std::string>> OwnRendererHeaders(const std::string& domain, bool main_frame,
                                                                           int browser_id, int owner_browser_id) {
  if (domain != kOwnRendererPageId) return {};
  if (!main_frame) return {{"Cross-Origin-Embedder-Policy", kOwnRendererEmbedderPolicy}};
  if (browser_id <= 0 || browser_id != owner_browser_id) return {};
  return {
      {"Cross-Origin-Opener-Policy", "same-origin"},
      {"Cross-Origin-Embedder-Policy", kOwnRendererEmbedderPolicy},
  };
}

// Whether a chat's top document must wait one UI (main) thread turn before it is answered
// (shim_page_scheme.mm's DeferredPageResource `after_ui_turn`). The turn exists so a browser the app names
// in the turn that created it (CEFOwnChatRenderer.attached) is seen. A browser already named needs no
// turn: its answer is the same either way, and on a launch that turn waits behind the app's own launch
// work on the main thread, on the front chat's path to its first paint.
inline bool OwnRendererNeedsUITurn(bool candidate, int browser_id, int owner_browser_id) {
  return candidate && !(browser_id > 0 && browser_id == owner_browser_id);
}

// Whether a bundled page file's request names its content (`?h=` and 8 to 64 hex digits, written by
// the page's build: build-agent-pane-web.sh's pane.css): that URL never names other bytes, so the
// answer may be kept (`Cache-Control: max-age=31536000, immutable`). Blink then hands every page of
// the renderer that links it the sheet it parsed once, where an answer it may not keep is fetched
// and parsed again per page (about 2 MB a chat page for the agent pane's sheet). Any other query, or
// none, is answered as before: a file without its hash may change under a live web loop.
inline bool IsContentHashedQuery(const std::string& query) {
  if (query.size() < 2 + 8 || query.size() > 2 + 64 || query.compare(0, 2, "h=") != 0) return false;
  for (size_t at = 2; at < query.size(); ++at) {
    const char c = query[at];
    if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))) return false;
  }
  return true;
}
inline constexpr char kImmutableCacheControl[] = "max-age=31536000, immutable";

// A header value from the page host: empty when it holds a CR or LF, so an answer cannot split a
// header (cmux_shim_page_resource_respond_page's CSP).
inline std::string PageHeaderValue(const std::string& value) {
  return value.find_first_of("\r\n") == std::string::npos ? value : std::string();
}

// The headers a ranged dynamic answer adds (cmux_shim_page_resource_respond_ranged):
// `Name: value` lines, newline-separated. Only Content-Range and Accept-Ranges
// are kept, and a value with a CR or LF is dropped, so an answer can never set
// the page's CSP or other page headers, or split a header.
inline std::vector<std::pair<std::string, std::string>> PageRangeHeaders(const std::string& text) {
  std::vector<std::pair<std::string, std::string>> out;
  size_t start = 0;
  while (start <= text.size()) {
    size_t end = text.find('\n', start);
    if (end == std::string::npos) end = text.size();
    std::string line = text.substr(start, end - start);
    start = end + 1;
    if (!line.empty() && line.back() == '\r') line.pop_back();
    const size_t colon = line.find(':');
    if (colon == std::string::npos) continue;
    std::string name = line.substr(0, colon);
    std::string value = line.substr(colon + 1);
    while (!value.empty() && value.front() == ' ') value.erase(value.begin());
    if (value.empty() || value.find('\r') != std::string::npos) continue;
    std::string lower = name;
    for (char& c : lower) c = static_cast<char>(tolower(static_cast<unsigned char>(c)));
    if (lower == "content-range") out.emplace_back("Content-Range", value);
    else if (lower == "accept-ranges") out.emplace_back("Accept-Ranges", value);
  }
  return out;
}

// A page host's Content-Type as CEF takes it: the bare type for SetMimeType and the charset for
// SetCharset. CEF hands Chromium the MIME type string unparsed, so `text/html; charset=utf-8` as a
// type is no HTML type, and a `text/` type Chromium does not know is drawn as plain text: a dev
// server's page showed its own source. Parameters other than charset are dropped.
inline void SplitPageMimeType(const std::string& content_type, std::string* mime, std::string* charset) {
  auto trim = [](std::string value) {
    const size_t first = value.find_first_not_of(" \t");
    if (first == std::string::npos) return std::string();
    return value.substr(first, value.find_last_not_of(" \t") - first + 1);
  };
  auto lower = [](std::string value) {
    for (char& c : value) c = static_cast<char>(tolower(static_cast<unsigned char>(c)));
    return value;
  };
  charset->clear();
  size_t semi = content_type.find(';');
  *mime = lower(trim(content_type.substr(0, semi)));
  while (semi != std::string::npos) {
    const size_t start = semi + 1;
    semi = content_type.find(';', start);
    const std::string parameter = trim(content_type.substr(start, semi == std::string::npos ? std::string::npos : semi - start));
    const size_t equals = parameter.find('=');
    if (equals == std::string::npos || lower(trim(parameter.substr(0, equals))) != "charset") continue;
    std::string value = trim(parameter.substr(equals + 1));
    if (value.size() >= 2 && value.front() == '"' && value.back() == '"') value = value.substr(1, value.size() - 2);
    *charset = lower(value);
  }
}

// A `Content-Range: bytes first-last/total` value; false for `*/total` or anything else.
inline bool ParseContentRange(const std::string& value, int64_t* first, int64_t* last, int64_t* total) {
  long long a = 0, b = 0, n = 0;
  char tail = 0;
  if (sscanf(value.c_str(), "bytes %lld-%lld/%lld%c", &a, &b, &n, &tail) != 3) return false;
  if (a < 0 || b < a || n <= b) return false;
  *first = a;
  *last = b;
  *total = n;
  return true;
}

// A media answer that goes to Chromium as the rest of the file, one chunk from the page host at a
// time. For a URL that is not http or https (cmux-page://), Chromium's media loader never reads
// Content-Range: it takes the file's length as the answer's length plus where it starts
// (ResourceMultiBufferDataProvider::DidReceiveResponse), and it asks for `bytes=N-`. The page host
// answers at most 8 MiB (AgentPaneSchemeHandler.mediaChunk), so a longer video looked 8 MiB long: a
// screen recording, whose index is at its end, never played in place or in the large viewer (Leo,
// 2026-11-03: "i can neither preview a vid in place nor have it pop up anymore"). The shim answers
// with the rest of the file's length and asks the page host for each next chunk as Chromium reads.
struct PageRangedStream {
  int64_t length = 0;  // the answer's length: from its first byte to the end of the file
  int64_t next = 0;    // the first byte not yet received from the page host
  int64_t total = 0;   // the file's size
  std::vector<std::pair<std::string, std::string>> headers;  // the answer's range headers
};

// Whether a page host's first answer (`status`, `headers` from PageRangeHeaders, `body_size` bytes)
// to a request with Range `request_range` is a chunk of an open-ended range that stops before the
// file's end; then *stream is how the shim answers instead. A closed or suffix range, a whole file,
// a 416 or a chunk that does not match its own Content-Range are answered as they are.
inline bool PlanRangedStream(const std::string& request_range, int status,
                             const std::vector<std::pair<std::string, std::string>>& headers, int64_t body_size,
                             PageRangedStream* stream) {
  if (status != 206 || body_size <= 0) return false;
  long long start = 0;
  char tail = 0;
  if (!request_range.empty() && (sscanf(request_range.c_str(), "bytes=%lld-%c", &start, &tail) != 1 || start < 0))
    return false;
  int64_t first = 0, last = 0, total = 0;
  bool ranged = false;
  for (const auto& [name, value] : headers)
    if (name == "Content-Range") ranged = ParseContentRange(value, &first, &last, &total);
  if (!ranged || first != start || last - first + 1 != body_size || last >= total - 1) return false;
  stream->length = total - first;
  stream->next = last + 1;
  stream->total = total;
  stream->headers.clear();
  stream->headers.emplace_back("Content-Range",
                               "bytes " + std::to_string(first) + "-" + std::to_string(total - 1) + "/" + std::to_string(total));
  stream->headers.emplace_back("Accept-Ranges", "bytes");
  return true;
}

// The Range the shim asks the page host for next.
inline std::string PageRangedStreamNextRange(const PageRangedStream& stream) {
  return "bytes=" + std::to_string(stream.next) + "-";
}

// Takes the page host's next chunk when it is the next part of the same file, and moves the stream
// past it; false (the stream fails) for anything else: a refusal, another place, another size.
inline bool AcceptRangedChunk(PageRangedStream* stream, int status,
                              const std::vector<std::pair<std::string, std::string>>& headers, int64_t body_size) {
  if (status != 206 || body_size <= 0 || stream->next >= stream->total) return false;
  int64_t first = 0, last = 0, total = 0;
  bool ranged = false;
  for (const auto& [name, value] : headers)
    if (name == "Content-Range") ranged = ParseContentRange(value, &first, &last, &total);
  if (!ranged || first != stream->next || total != stream->total || last - first + 1 != body_size) return false;
  stream->next = last + 1;
  return true;
}

// The reason phrase a dynamic answer's status carries.
inline const char* PageStatusText(int status) {
  switch (status) {
    case 200: return "OK";
    case 206: return "Partial Content";
    case 416: return "Range Not Satisfiable";
    default: return "Not Found";
  }
}

}  // namespace cmux_shim

#endif  // CMUX_SHIM_CMUX_PAGE_PATH_H_
