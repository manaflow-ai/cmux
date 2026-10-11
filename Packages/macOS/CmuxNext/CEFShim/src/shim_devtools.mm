// DevTools of a page browser. Every way Chromium opens DevTools (our
// commands, Chromium's IDC_DEV_TOOLS_* commands, the page context menu's
// Inspect) reaches OnBeforeDevToolsPopup of the page's client, which asks
// the host where DevTools goes (a docked parent view in the pane, or its
// own window) and gives the DevTools browser its own client. That client
// reports only DevTools lifetime, so a DevTools browser never becomes a
// tab and never writes a URL or title into one.

#import <AppKit/AppKit.h>

#include <algorithm>

#include "include/cef_command_ids.h"
#include "shim_internal.h"

namespace cmux_shim {

namespace {

struct Placement {
  void* parent_view = nullptr;  // NSView*; nullptr = own window
  int x = 0;
  int y = 0;
  int width = 0;
  int height = 0;
};

// Inspected browser id -> where its DevTools goes next.
std::map<int, Placement>& placements() {
  static std::map<int, Placement> map;
  return map;
}

// Inspected browser id -> its live DevTools browser.
std::map<int, CefRefPtr<CefBrowser>>& devtools_browsers() {
  static std::map<int, CefRefPtr<CefBrowser>> map;
  return map;
}

CefRefPtr<CefBrowser> DevToolsOf(int inspected) {
  auto& map = devtools_browsers();
  auto it = map.find(inspected);
  return it == map.end() ? nullptr : it->second;
}

class DevToolsClient : public CefClient, public CefLifeSpanHandler, public CefKeyboardHandler {
 public:
  DevToolsClient(int inspected, bool docked) : inspected_(inspected), docked_(docked) {}

  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
  CefRefPtr<CefKeyboardHandler> GetKeyboardHandler() override { return this; }

  void OnAfterCreated(CefRefPtr<CefBrowser> browser) override {
    auto& map = devtools_browsers();
    if (map.count(inspected_) == 0) {
      map[inspected_] = browser;
    }
    Emit(CMUX_SHIM_DEVTOOLS_OPENED, inspected_, 0, browser->GetIdentifier(), docked_ ? 1 : 0);
  }

  bool OnBeforePopup(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>, int, const CefString&, const CefString&,
                     WindowOpenDisposition, bool, const CefPopupFeatures&, CefWindowInfo&, CefRefPtr<CefClient>&,
                     CefBrowserSettings&, CefRefPtr<CefDictionaryValue>&, bool*) override {
    // DevTools opens no windows of its own.
    return true;
  }

  bool DoClose(CefRefPtr<CefBrowser>) override {
    // A docked DevTools lives in a parent view the host owns; its own
    // window closes normally.
    return docked_;
  }

  void OnBeforeClose(CefRefPtr<CefBrowser> browser) override {
    auto& map = devtools_browsers();
    auto it = map.find(inspected_);
    if (it != map.end() && it->second->IsSame(browser)) {
      map.erase(it);
    }
    Emit(CMUX_SHIM_DEVTOOLS_CLOSED, inspected_, 0, browser->GetIdentifier());
  }

  bool OnPreKeyEvent(CefRefPtr<CefBrowser>, const CefKeyEvent& event, CefEventHandle os_event, bool*) override {
    Host& h = host();
    if (!h.devtools_key || !os_event || event.type != KEYEVENT_RAWKEYDOWN) {
      return false;
    }
    return h.devtools_key(h.ctx, inspected_, (__bridge void*)os_event) != 0;
  }

 private:
  int inspected_;
  bool docked_;
  IMPLEMENT_REFCOUNTING(DevToolsClient);
};

}  // namespace

void PrepareDevToolsPopup(int inspected, CefWindowInfo& window_info, CefRefPtr<CefClient>& client,
                          bool* use_default_window) {
  // The host decides now (synchronously, from this event) and calls
  // cmux_shim_devtools_set_placement.
  Emit(CMUX_SHIM_DEVTOOLS_WILL_OPEN, inspected);
  Placement placement;
  auto it = placements().find(inspected);
  if (it != placements().end()) {
    placement = it->second;
  }
  CefWindowInfo info;
  if (placement.parent_view) {
    info.SetAsChild((__bridge CefWindowHandle)(__bridge NSView*)placement.parent_view,
                    CefRect(0, 0, std::max(placement.width, 1), std::max(placement.height, 1)));
  } else if (placement.width > 0 && placement.height > 0) {
    info.bounds = CefRect(placement.x, placement.y, placement.width, placement.height);
  }
  info.runtime_style = CEF_RUNTIME_STYLE_CHROME;
  window_info = info;
  client = new DevToolsClient(inspected, placement.parent_view != nullptr);
  if (use_default_window) {
    // Never a Views-hosted popup: the window info above decides.
    *use_default_window = true;
  }
}

void ForgetDevTools(int inspected) {
  placements().erase(inspected);
}

}  // namespace cmux_shim

using namespace cmux_shim;

extern "C" {

void cmux_shim_devtools_set_key_handler(cmux_shim_key_fn key) {
  host().devtools_key = key;
}

void cmux_shim_devtools_set_placement(int browser_id, void* parent_view, int x, int y, int width, int height) {
  placements()[browser_id] = Placement{parent_view, x, y, width, height};
}

int cmux_shim_devtools_command(int browser_id, int command, int x, int y) {
  CefRefPtr<CefBrowser> browser = BrowserById(browser_id);
  CefRefPtr<CefBrowserHost> page = browser ? browser->GetHost() : nullptr;
  if (!page) {
    return 0;
  }
  switch (command) {
    case CMUX_SHIM_DEVTOOLS_SHOW:
      if (CefRefPtr<CefBrowser> open = DevToolsOf(browser_id)) {
        open->GetHost()->SetFocus(true);
      } else {
        page->ShowDevTools(CefWindowInfo(), nullptr, CefBrowserSettings(), CefPoint());
      }
      return 1;
    case CMUX_SHIM_DEVTOOLS_CONSOLE:
    case CMUX_SHIM_DEVTOOLS_INSPECT: {
      // Chromium's own commands on the page's Browser (its active tab is
      // the page: the host activates the shown tab).
      int id = command == CMUX_SHIM_DEVTOOLS_CONSOLE ? IDC_DEV_TOOLS_CONSOLE : IDC_DEV_TOOLS_INSPECT;
      if (page->CanExecuteChromeCommand(id)) {
        page->ExecuteChromeCommand(id, CEF_WOD_CURRENT_TAB);
      } else {
        page->ShowDevTools(CefWindowInfo(), nullptr, CefBrowserSettings(), CefPoint());
      }
      return 1;
    }
    case CMUX_SHIM_DEVTOOLS_INSPECT_AT:
      page->ShowDevTools(CefWindowInfo(), nullptr, CefBrowserSettings(), CefPoint(x, y));
      return 1;
    case CMUX_SHIM_DEVTOOLS_CLOSE:
      page->CloseDevTools();
      return 1;
    default:
      return 0;
  }
}

int cmux_shim_devtools_browser(int browser_id) {
  CefRefPtr<CefBrowser> open = DevToolsOf(browser_id);
  return open ? open->GetIdentifier() : 0;
}

void cmux_shim_devtools_set_focus(int browser_id, int focus) {
  if (CefRefPtr<CefBrowser> open = DevToolsOf(browser_id)) {
    open->GetHost()->SetFocus(focus != 0);
  }
}

}  // extern "C"
