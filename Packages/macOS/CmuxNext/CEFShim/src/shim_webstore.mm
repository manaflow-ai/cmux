// Chrome Web Store: the store shows "Switch to Chrome" unless the page
// request carries the x-browser-copyright and x-browser-year headers that
// Google Chrome sends (plans/cmux-next/browser.md, "Web Store install").
// The store only checks that both are present; cmux sends its own values,
// and only to the store's origin.

#include <ctime>

#include "include/cef_resource_request_handler.h"
#include "include/cef_parser.h"
#include "shim_internal.h"

namespace cmux_shim {

namespace {

class WebStoreHeaders : public CefResourceRequestHandler {
 public:
  cef_return_value_t OnBeforeResourceLoad(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>, CefRefPtr<CefRequest> request,
                                          CefRefPtr<CefCallback>) override {
    const std::string year = std::to_string(CurrentYear());
    request->SetHeaderByName("x-browser-copyright", "Copyright " + year + " Manaflow. All rights reserved.", true);
    request->SetHeaderByName("x-browser-year", year, true);
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

bool IsWebStoreURL(const std::string& url) {
  CefURLParts parts;
  if (!CefParseURL(url, parts)) return false;
  return CefString(&parts.scheme).ToString() == "https" &&
         CefString(&parts.host).ToString() == "chromewebstore.google.com";
}

CefRefPtr<CefResourceRequestHandler> WebStoreRequestHandler(const std::string& url) {
  static CefRefPtr<CefResourceRequestHandler> handler = new WebStoreHeaders();
  return IsWebStoreURL(url) ? handler : nullptr;
}

}  // namespace cmux_shim
