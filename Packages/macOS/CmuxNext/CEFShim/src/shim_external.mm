// A page's links to other apps (cx-d0d.22): a main-frame navigation to a
// scheme Chromium cannot load (mailto:, tel:, an app's own scheme) reaches
// OnProtocolExecution. Chromium never runs the OS handler itself, so it
// never shows its own external-protocol dialog: the shim reports the URL as
// EXTERNAL_URL with whether the navigation came from the user's click, and
// the host opens it in its app or asks first (BrowserExternalApps).

#include <map>
#include <utility>

#include "include/cef_resource_request_handler.h"
#include "include/cef_task.h"
#include "shim_internal.h"

namespace cmux_shim {

namespace {

// The last main-frame navigation of each browser and whether the user's
// gesture started it, from OnBeforeBrowse (UI thread).
std::map<int, std::pair<std::string, bool>>& navigation_gestures() {
  static std::map<int, std::pair<std::string, bool>> map;
  return map;
}

class ExternalURLTask : public CefTask {
 public:
  ExternalURLTask(int browser_id, std::string url) : browser_id_(browser_id), url_(std::move(url)) {}

  void Execute() override {
    auto& gestures = navigation_gestures();
    auto it = gestures.find(browser_id_);
    const bool gesture = it != gestures.end() && it->second.first == url_ && it->second.second;
    Emit(CMUX_SHIM_EXTERNAL_URL, browser_id_, 0, gesture ? 1 : 0, 0, url_);
  }

 private:
  int browser_id_;
  std::string url_;
  IMPLEMENT_REFCOUNTING(ExternalURLTask);
};

class MainFrameNavigation : public CefResourceRequestHandler {
 public:
  // IO thread.
  void OnProtocolExecution(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame>, CefRefPtr<CefRequest> request,
                           bool& allow_os_execution) override {
    allow_os_execution = false;
    if (!browser) return;
    CefPostTask(TID_UI, new ExternalURLTask(browser->GetIdentifier(), request->GetURL().ToString()));
  }

 private:
  IMPLEMENT_REFCOUNTING(MainFrameNavigation);
};

}  // namespace

void RecordNavigationGesture(int browser_id, const std::string& url, bool gesture) {
  navigation_gestures()[browser_id] = {url, gesture};
}

void ForgetNavigationGesture(int browser_id) {
  navigation_gestures().erase(browser_id);
}

CefRefPtr<CefResourceRequestHandler> NavigationRequestHandler(const std::string& url, bool main_frame_navigation) {
  if (IsWebStoreURL(url)) return WebStoreRequestHandler(url);
  static CefRefPtr<CefResourceRequestHandler> handler = new MainFrameNavigation();
  return main_frame_navigation ? handler : nullptr;
}

}  // namespace cmux_shim
