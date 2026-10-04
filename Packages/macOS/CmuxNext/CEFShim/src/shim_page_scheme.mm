// cmux-page://<id>/ app pages served from a folder (cmux_shim_page_scheme_add).
// The scheme itself is registered in every process at startup
// (page_scheme_registration.h). Each id gets its own scheme handler factory
// for the domain <id>, on the global context and on every request context
// the shim creates (each profile keeps its own factories). The path rules
// live in cmux_page_path.h (scripts/cmux-next/test-cmux-page-path-cpp.sh).

#include "cmux_page_path.h"
#include "include/cef_parser.h"
#include "include/cef_scheme.h"
#include "include/wrapper/cef_stream_resource_handler.h"
#include "shim_internal.h"

namespace cmux_shim {

namespace {

// Immutable after construction: Create runs off the UI thread.
class PageFactory : public CefSchemeHandlerFactory {
 public:
  PageFactory(std::string root, std::string csp) : root_(std::move(root)), csp_(std::move(csp)) {}

  CefRefPtr<CefResourceHandler> Create(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>, const CefString&,
                                       CefRefPtr<CefRequest> request) override {
    if (request->GetMethod().ToString() != "GET") {
      static char kBody[] = "Method Not Allowed";
      CefResponse::HeaderMap headers = Headers();
      headers.emplace("Allow", "GET");
      return Respond(405, "Method Not Allowed", "text/plain", headers, kBody, sizeof(kBody) - 1);
    }
    CefURLParts parts;
    std::string file;
    std::string mime;
    if (CefParseURL(request->GetURL(), parts) &&
        ResolvePagePath(root_, CefString(&parts.path).ToString(), &file, &mime)) {
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
    headers.emplace("Content-Security-Policy", csp_);
    headers.emplace("X-Content-Type-Options", "nosniff");
    return headers;
  }

  // body is static storage, so the reader may keep pointing at it.
  static CefRefPtr<CefResourceHandler> Respond(int status, const char* text, const char* mime,
                                               const CefResponse::HeaderMap& headers, char* body, size_t size) {
    return new CefStreamResourceHandler(status, text, mime, headers, CefStreamReader::CreateForData(body, size));
  }

  const std::string root_;
  const std::string csp_;
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

// first_party: only reserved ids; otherwise: never a reserved id.
int AddPage(const char* id, const char* resource_root, const char* csp, bool first_party) {
  std::string domain;
  if (!id || !NormalizePageId(id, &domain) || !resource_root || !*resource_root) return 0;
  if (IsReservedPageId(domain) != first_party) return 0;
  std::string root;
  if (!page_detail::RealPath(resource_root, &root)) return 0;
  struct stat info;
  if (stat(root.c_str(), &info) != 0 || !S_ISDIR(info.st_mode)) return 0;
  // Pinned to its real path now (a later symlink swap of the given path
  // cannot move it); ResolvePagePath checks real paths again per request.
  CefRefPtr<PageFactory> factory = new PageFactory(root, csp ? csp : kCmuxPageDefaultCSP);
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

}  // extern "C"
