// Chrome Web Store: the store shows "Switch to Chrome" unless the page
// request carries the x-browser-copyright and x-browser-year headers that
// Google Chrome sends and a sec-ch-ua brand list naming "Google Chrome"
// (webstore_headers.h; plans/cmux-next/browser.md, "Web Store install").
// The store only checks that they are present; cmux sends its own
// copyright, and all of it only to the store's origin and, from a store
// page, to the Google bar's promo API (its "Switch to Chrome?" card).

#include <ctime>

#include "include/cef_resource_request_handler.h"
#include "include/cef_parser.h"
#include "shim_internal.h"
#include "webstore_headers.h"

namespace cmux_shim {

namespace {

class WebStoreHeaders : public CefResourceRequestHandler {
 public:
  cef_return_value_t OnBeforeResourceLoad(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>, CefRefPtr<CefRequest> request,
                                          CefRefPtr<CefCallback>) override {
    const int year = CurrentYear();
    request->SetHeaderByName("x-browser-copyright", WebStoreCopyright(year), true);
    request->SetHeaderByName("x-browser-year", std::to_string(year), true);
    const std::string brands = request->GetHeaderByName("sec-ch-ua").ToString();
    const std::string store_brands = WebStoreBrandList(brands, request->GetHeaderByName("User-Agent").ToString());
    if (!store_brands.empty() && store_brands != brands) request->SetHeaderByName("sec-ch-ua", store_brands, true);
    // sec-ch-ua-full-version-list stays Chromium's: naming Google Chrome there turns the store's
    // banner flag back off (curl, 2026-11-16), so it is never touched (webstore_headers.h).
    return RV_CONTINUE;
  }

 private:
  static int CurrentYear() {
    std::time_t now = std::time(nullptr);
    std::tm parts{};
    gmtime_r(&now, &parts);
    return parts.tm_year + 1900;
  }

  IMPLEMENT_REFCOUNTING(WebStoreHeaders);
};

}  // namespace

bool IsWebStoreURL(const std::string& url) { return HttpsHost(url) == kWebStoreHost; }

bool IsWebStoreCrxURL(const std::string& url) {
  CefURLParts parts;
  if (!CefParseURL(url, parts)) return false;
  return CefString(&parts.scheme).ToString() == "https" &&
         CefString(&parts.host).ToString() == "clients2.google.com" &&
         CefString(&parts.path).ToString() == "/service/update2/crx";
}

CefRefPtr<CefResourceRequestHandler> WebStoreRequestHandler(const std::string& url, const std::string& page_url) {
  static CefRefPtr<CefResourceRequestHandler> handler = new WebStoreHeaders();
  return WebStoreSendsChromeHeaders(url, page_url) ? handler : nullptr;
}

}  // namespace cmux_shim
