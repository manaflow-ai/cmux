// cmux-page://<id>/ app pages served from a folder (cmux_shim_page_scheme_add).
// The scheme itself is registered in every process at startup
// (page_scheme_registration.h). Each id gets its own scheme handler factory
// for the domain <id>, on the global context and on every request context
// the shim creates (each profile keeps its own factories). The path rules
// live in cmux_page_path.h (scripts/cmux-next/test-cmux-page-path-cpp.sh).

#include <algorithm>
#include <atomic>
#include <cstring>
#include <mutex>

#include "cmux_page_path.h"
#include "include/cef_parser.h"
#include "include/cef_resource_handler.h"
#include "include/cef_scheme.h"
#include "include/cef_task.h"
#include "include/wrapper/cef_stream_resource_handler.h"
#include "shim_internal.h"

namespace cmux_shim {

namespace {

// One request for a dynamic path (IsDynamicPagePath), answered by the page
// host: Open emits CMUX_SHIM_PAGE_RESOURCE on the UI thread and waits for
// cmux_shim_page_resource_respond(token, ...). CEF calls the handler's
// methods in sequence on its IO sequence; Respond runs on the main thread,
// so the answer and the waiting callback are guarded by mutex_.
class DynamicResource : public CefResourceHandler {
 public:
  DynamicResource(int token, int browser_id, std::string url, std::string csp)
      : token_(token), browser_id_(browser_id), url_(std::move(url)), csp_(std::move(csp)) {}

  bool Open(CefRefPtr<CefRequest>, bool& handle_request, CefRefPtr<CefCallback> callback) override;
  void GetResponseHeaders(CefRefPtr<CefResponse> response, int64_t& response_length, CefString&) override {
    std::lock_guard<std::mutex> lock(mutex_);
    response->SetStatus(status_);
    response->SetStatusText(PageStatusText(status_));
    response->SetMimeType(mime_);
    CefResponse::HeaderMap headers;
    // A live page file (cmux_shim_page_scheme_set_live) carries the policy the page host chose for
    // it (a dev server's adds its HMR socket); every other answer keeps the page's own.
    for (auto& [name, value] : PageResponseHeaders(answer_csp_.empty() ? csp_ : answer_csp_)) headers.emplace(name, value);
    for (auto& [name, value] : range_headers_) headers.emplace(name, value);
    headers.emplace("Cache-Control", "no-store");
    response->SetHeaderMap(headers);
    response_length = static_cast<int64_t>(body_.size());
  }
  bool Read(void* data_out, int bytes_to_read, int& bytes_read, CefRefPtr<CefResourceReadCallback>) override {
    std::lock_guard<std::mutex> lock(mutex_);
    const size_t left = body_.size() - offset_;
    const size_t count = std::min(left, static_cast<size_t>(std::max(bytes_to_read, 0)));
    if (count == 0) {
      bytes_read = 0;
      return false;
    }
    memcpy(data_out, body_.data() + offset_, count);
    offset_ += count;
    bytes_read = static_cast<int>(count);
    return true;
  }
  void Cancel() override;

  // The page host's answer (main thread). False when the request already
  // ended (cancelled) or was answered.
  bool Respond(int status, std::string mime, std::string body, std::string range_headers = "", std::string csp = "") {
    CefRefPtr<CefCallback> callback;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      if (answered_ || !callback_) return false;
      answered_ = true;
      status_ = status;
      mime_ = mime.empty() ? "application/octet-stream" : std::move(mime);
      body_ = std::move(body);
      range_headers_ = PageRangeHeaders(range_headers);
      answer_csp_ = PageHeaderValue(csp);
      callback = callback_;
      callback_ = nullptr;
    }
    callback->Continue();
    return true;
  }

  int browser_id() const { return browser_id_; }
  const std::string& url() const { return url_; }

 private:
  const int token_;
  const int browser_id_;
  const std::string url_;
  const std::string csp_;
  std::mutex mutex_;
  CefRefPtr<CefCallback> callback_;
  bool answered_ = false;
  int status_ = 404;
  std::string mime_ = "text/plain";
  std::string body_;
  std::vector<std::pair<std::string, std::string>> range_headers_;
  std::string answer_csp_;
  size_t offset_ = 0;
  IMPLEMENT_REFCOUNTING(DynamicResource);
};

// Requests waiting for the page host, by token (any thread).
std::mutex& pending_mutex() {
  static std::mutex mutex;
  return mutex;
}
std::map<int, CefRefPtr<DynamicResource>>& pending() {
  static std::map<int, CefRefPtr<DynamicResource>> map;
  return map;
}
int NextToken() {
  static std::atomic<int> next{0};
  int token = ++next;
  if (token <= 0) {
    next = 1;
    token = 1;
  }
  return token;
}

class EmitResourceTask : public CefTask {
 public:
  EmitResourceTask(int token, int browser_id, std::string url, std::string range)
      : token_(token), browser_id_(browser_id), url_(std::move(url)), range_(std::move(range)) {}
  void Execute() override { Emit(CMUX_SHIM_PAGE_RESOURCE, browser_id_, token_, 0, 0, url_, range_); }

 private:
  const int token_;
  const int browser_id_;
  const std::string url_;
  const std::string range_;
  IMPLEMENT_REFCOUNTING(EmitResourceTask);
};

bool DynamicResource::Open(CefRefPtr<CefRequest> request, bool& handle_request, CefRefPtr<CefCallback> callback) {
  handle_request = false;
  // A <video> asks for one byte range at a time; the page host answers it (206).
  const std::string range = request ? request->GetHeaderByName("Range").ToString() : std::string();
  {
    std::lock_guard<std::mutex> lock(mutex_);
    callback_ = callback;
  }
  {
    std::lock_guard<std::mutex> lock(pending_mutex());
    pending()[token_] = this;
  }
  CefPostTask(TID_UI, new EmitResourceTask(token_, browser_id_, url_, range));
  return true;
}

void DynamicResource::Cancel() {
  {
    std::lock_guard<std::mutex> lock(mutex_);
    callback_ = nullptr;
  }
  std::lock_guard<std::mutex> lock(pending_mutex());
  pending().erase(token_);
}

// Whether every request of a first-party page goes to the page host, as a dynamic path does
// (cmux_shim_page_scheme_set_live): the live web loop (web-dev.json) then serves page files from a
// dev server or an overlay folder instead of the folder fixed at registration. Read per request.
std::atomic<bool> g_live_pages{false};

// Immutable after construction: Create runs off the UI thread.
class PageFactory : public CefSchemeHandlerFactory {
 public:
  PageFactory(std::string domain, std::string root, std::string csp, std::vector<std::string> dynamic_prefixes,
              std::string entry)
      : domain_(std::move(domain)), root_(std::move(root)), csp_(std::move(csp)),
        dynamic_prefixes_(std::move(dynamic_prefixes)), entry_(std::move(entry)) {}

  CefRefPtr<CefResourceHandler> Create(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, const CefString&,
                                       CefRefPtr<CefRequest> request) override {
    const bool main_frame = request->GetResourceType() == RT_MAIN_FRAME;
    std::string frame_url;
    std::string parent_url;
    if (frame) {
      frame_url = frame->GetURL().ToString();
      if (CefRefPtr<CefFrame> parent = frame->GetParent()) parent_url = parent->GetURL().ToString();
    }
    const std::string url = request->GetURL().ToString();
    if (IsArtifactFrameURL(url)) {
      if (domain_ != "cmux.agent" || request->GetMethod().ToString() != "GET" ||
          request->GetResourceType() != RT_SUB_FRAME ||
          ArtifactNavigationRefused(main_frame, frame_url, parent_url, url)) {
        static char kBody[] = "Forbidden";
        return Respond(403, "Forbidden", "text/plain", Headers(), kBody, sizeof(kBody) - 1);
      }
      CefResponse::HeaderMap headers;
      headers.emplace("Content-Security-Policy", kArtifactCSP);
      headers.emplace("Cache-Control", "no-store");
      headers.emplace("X-Content-Type-Options", "nosniff");
      headers.emplace("Referrer-Policy", "no-referrer");
      return Respond(200, "OK", "text/html", headers, kArtifactDocument, sizeof(kArtifactDocument) - 1);
    }
    if (!PageRequestAllowed(main_frame, frame_url, parent_url, domain_)) {
      static char kBody[] = "Forbidden";
      return Respond(403, "Forbidden", "text/plain", Headers(), kBody, sizeof(kBody) - 1);
    }
    if (request->GetMethod().ToString() != "GET") {
      static char kBody[] = "Method Not Allowed";
      CefResponse::HeaderMap headers = Headers();
      headers.emplace("Allow", "GET");
      return Respond(405, "Method Not Allowed", "text/plain", headers, kBody, sizeof(kBody) - 1);
    }
    CefURLParts parts;
    std::string file;
    std::string mime;
    const bool parsed = CefParseURL(request->GetURL(), parts);
    if (parsed && IsDynamicPagePath(CefString(&parts.path).ToString(), dynamic_prefixes_)) {
      // A generated file of one page view: only a page in a browser can ask.
      if (browser) return new DynamicResource(NextToken(), browser->GetIdentifier(), request->GetURL().ToString(), csp_);
      static char kBody[] = "Not Found";
      return Respond(404, "Not Found", "text/plain", Headers(), kBody, sizeof(kBody) - 1);
    }
    // Live: the page host answers every file (server, then overlay, then web update, then bundle).
    if (parsed && browser && g_live_pages.load(std::memory_order_relaxed)) {
      return new DynamicResource(NextToken(), browser->GetIdentifier(), request->GetURL().ToString(), csp_);
    }
    std::string path = parsed ? CefString(&parts.path).ToString() : std::string();
    // "/" is the page's entry document (a shared build folder names its own).
    if ((path.empty() || path == "/") && !entry_.empty()) path = "/" + entry_;
    if (parsed && ResolvePagePath(root_, path, &file, &mime)) {
      if (CefRefPtr<CefStreamReader> stream = CefStreamReader::CreateForFile(file)) {
        return new CefStreamResourceHandler(200, "OK", mime, Headers(), stream);
      }
    }
    static char kBody[] = "Not Found";
    return Respond(404, "Not Found", "text/plain", Headers(), kBody, sizeof(kBody) - 1);
  }

 private:
  CefResponse::HeaderMap Headers() const {
    CefResponse::HeaderMap headers;
    for (auto& [name, value] : PageResponseHeaders(csp_)) headers.emplace(name, value);
    return headers;
  }

  // body is static storage, so the reader may keep pointing at it.
  static CefRefPtr<CefResourceHandler> Respond(int status, const char* text, const char* mime,
                                               const CefResponse::HeaderMap& headers, char* body, size_t size) {
    return new CefStreamResourceHandler(status, text, mime, headers, CefStreamReader::CreateForData(body, size));
  }

  const std::string domain_;
  const std::string root_;
  const std::string csp_;
  const std::vector<std::string> dynamic_prefixes_;
  const std::string entry_;
  IMPLEMENT_REFCOUNTING(PageFactory);
};

// Page id -> its factory (UI thread).
std::map<std::string, CefRefPtr<PageFactory>>& pages() {
  static std::map<std::string, CefRefPtr<PageFactory>> map;
  return map;
}

bool g_global_ready = false;

}  // namespace

void RegisterPageSchemes(CefRefPtr<CefRequestContext> context) {
  if (!context) return;
  for (auto& [id, factory] : pages()) {
    context->RegisterSchemeHandlerFactory(kCmuxPageScheme, id, factory);
  }
}

void InstallPageSchemes() {
  g_global_ready = true;
  for (auto& [id, factory] : pages()) {
    CefRegisterSchemeHandlerFactory(kCmuxPageScheme, id, factory);
  }
}

}  // namespace cmux_shim

using namespace cmux_shim;

namespace {

// Newline-separated prefixes; empty lines are skipped.
std::vector<std::string> SplitPrefixes(const char* text) {
  std::vector<std::string> out;
  if (!text) return out;
  std::string all = text;
  size_t start = 0;
  while (start <= all.size()) {
    size_t end = all.find('\n', start);
    std::string part = all.substr(start, end == std::string::npos ? std::string::npos : end - start);
    if (!part.empty()) out.push_back(part);
    if (end == std::string::npos) break;
    start = end + 1;
  }
  return out;
}

// first_party: only reserved ids; otherwise: never a reserved id.
int AddPage(const char* id, const char* resource_root, const char* csp, bool first_party,
            const char* dynamic_prefixes = nullptr, const char* entry = nullptr) {
  // A plain file name: no path, no escape (ResolvePagePath checks it again).
  std::string entry_name = entry && *entry ? entry : "";
  if (entry_name.find('/') != std::string::npos || entry_name.find('\\') != std::string::npos || entry_name == "." ||
      entry_name == "..") {
    return 0;
  }
  std::string domain;
  if (!id || !NormalizePageId(id, &domain) || !resource_root || !*resource_root) return 0;
  if (IsReservedPageId(domain) != first_party) return 0;
  std::string root;
  if (!page_detail::RealPath(resource_root, &root)) return 0;
  struct stat info;
  if (stat(root.c_str(), &info) != 0 || !S_ISDIR(info.st_mode)) return 0;
  // Pinned to its real path now (a later symlink swap of the given path
  // cannot move it); ResolvePagePath checks real paths again per request.
  CefRefPtr<PageFactory> factory =
      new PageFactory(domain, root, csp ? csp : kCmuxPageDefaultCSP, SplitPrefixes(dynamic_prefixes), entry_name);
  pages()[domain] = factory;
  if (g_global_ready) CefRegisterSchemeHandlerFactory(kCmuxPageScheme, domain, factory);
  ForEachRequestContext([&](CefRefPtr<CefRequestContext> context) {
    context->RegisterSchemeHandlerFactory(kCmuxPageScheme, domain, factory);
  });
  return 1;
}

}  // namespace

extern "C" {

int cmux_shim_page_scheme_add(const char* id, const char* resource_root, const char* csp) {
  return AddPage(id, resource_root, csp, false);
}

int cmux_shim_page_scheme_add_first_party(const char* id, const char* resource_root, const char* csp) {
  return AddPage(id, resource_root, csp, true);
}

int cmux_shim_page_scheme_add_first_party_dynamic(const char* id, const char* resource_root, const char* csp,
                                                  const char* dynamic_prefixes, const char* entry) {
  return AddPage(id, resource_root, csp, true, dynamic_prefixes, entry);
}

int cmux_shim_page_resource_respond(int token, int status, const char* mime, const void* body, size_t length) {
  CefRefPtr<DynamicResource> resource;
  {
    std::lock_guard<std::mutex> lock(pending_mutex());
    auto found = pending().find(token);
    if (found == pending().end()) return 0;
    resource = found->second;
    pending().erase(found);
  }
  std::string bytes;
  if (body && length > 0) bytes.assign(static_cast<const char*>(body), length);
  return resource->Respond(status, mime ? mime : "", std::move(bytes)) ? 1 : 0;
}

int cmux_shim_page_resource_respond_ranged(int token, int status, const char* mime, const char* range_headers,
                                           const void* body, size_t length) {
  CefRefPtr<DynamicResource> resource;
  {
    std::lock_guard<std::mutex> lock(pending_mutex());
    auto found = pending().find(token);
    if (found == pending().end()) return 0;
    resource = found->second;
    pending().erase(found);
  }
  std::string bytes;
  if (body && length > 0) bytes.assign(static_cast<const char*>(body), length);
  return resource->Respond(status, mime ? mime : "", std::move(bytes), range_headers ? range_headers : "") ? 1 : 0;
}

int cmux_shim_page_resource_respond_page(int token, int status, const char* mime, const char* range_headers,
                                         const char* csp, const void* body, size_t length) {
  CefRefPtr<DynamicResource> resource;
  {
    std::lock_guard<std::mutex> lock(pending_mutex());
    auto found = pending().find(token);
    if (found == pending().end()) return 0;
    resource = found->second;
    pending().erase(found);
  }
  std::string bytes;
  if (body && length > 0) bytes.assign(static_cast<const char*>(body), length);
  return resource->Respond(status, mime ? mime : "", std::move(bytes), range_headers ? range_headers : "",
                           csp ? csp : "")
             ? 1
             : 0;
}

void cmux_shim_page_scheme_set_live(int live) { g_live_pages.store(live != 0, std::memory_order_relaxed); }

}  // extern "C"
