// DevTools of a page browser. Every way Chromium opens DevTools (our
// commands, Chromium's IDC_DEV_TOOLS_* commands, the page context menu's
// Inspect) reaches OnBeforeDevToolsPopup of the page's client, which asks
// the host where DevTools goes (a docked parent view in the pane, or its
// own window) and gives the DevTools browser its own client. That client
// reports only DevTools lifetime, so a DevTools browser never becomes a
// tab and never writes a URL or title into one.

#import <AppKit/AppKit.h>

#include <algorithm>
#include <set>
#include <string>

#include "devtools_ready.h"
#include "include/base/cef_callback.h"
#include "include/cef_command_ids.h"
#include "include/wrapper/cef_closure_task.h"
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

// Inspected browser id -> the panel to select once its DevTools frontend
// has loaded (cmux_shim_devtools_show_panel while DevTools opens).
std::map<int, std::string>& pending_panels() {
  static std::map<int, std::string> map;
  return map;
}

// Inspected browser ids whose DevTools frontend finished loading.
std::set<int>& loaded_frontends() {
  static std::set<int> set;
  return set;
}

bool IsPanelId(const char* panel) {
  if (!panel || !*panel) return false;
  for (const char* c = panel; *c; ++c) {
    const bool ok = (*c >= 'a' && *c <= 'z') || (*c >= '0' && *c <= '9') || *c == '-';
    if (!ok || c - panel > 64) return false;
  }
  return true;
}

// DevToolsAPI.showPanel is the call Chrome makes for OpenDevToolsWindow's
// panel. Right after the frontend loads, the panel list may still be
// building, so a cold open asks again a moment later (in the frontend's own
// timers); an already open DevTools selects it at once.
void SelectPanel(CefRefPtr<CefBrowser> devtools, const std::string& panel, bool cold) {
  std::string script = "(function(p){var f=function(){try{DevToolsAPI.showPanel(p);}catch(e){}};f();";
  if (cold) script += "setTimeout(f,300);setTimeout(f,1200);";
  script += "})('" + panel + "');";
  devtools->GetMainFrame()->ExecuteJavaScript(script, "devtools://cmux/show-panel", 0);
}

// The window that shows DevTools browser's view, when it is a window of its own (a Chromium child window over the
// host's parent view); nil when the view sits in the parent's own window (never hide that one).
NSWindow* DevToolsOwnWindow(CefRefPtr<CefBrowser> browser, void* parent_view) {
  if (!browser) return nil;
  NSView* view = (__bridge NSView*)browser->GetHost()->GetWindowHandle();
  NSWindow* window = view.window;
  NSWindow* parent = parent_view ? ((__bridge NSView*)parent_view).window : nil;
  if (!window || window == parent) return nil;
  return window;
}

// Shows a DevTools window kept invisible until its frontend loaded (DevToolsClient). Reads no parent view: the
// backstop runs later, when the host view may be gone; an opaque window (the parent's own) stays as it is.
// The DevTools windows this file made invisible (weak: a closed DevTools' window just leaves).
NSHashTable<NSWindow*>* HiddenDevToolsWindows() {
  static NSHashTable<NSWindow*>* table = [NSHashTable weakObjectsHashTable];
  return table;
}

void RevealDevTools(CefRefPtr<CefBrowser> browser) {
  if (!browser) return;
  NSView* view = (__bridge NSView*)browser->GetHost()->GetWindowHandle();
  NSWindow* window = view.window;
  if (!window || ![HiddenDevToolsWindows() containsObject:window]) return;
  [HiddenDevToolsWindows() removeObject:window];
  window.alphaValue = 1;
}

class DevToolsClient : public CefClient, public CefLifeSpanHandler, public CefKeyboardHandler, public CefLoadHandler,
                       public CefDisplayHandler {
 public:
  DevToolsClient(int inspected, void* parent_view)
      : inspected_(inspected), docked_(parent_view != nullptr), parent_view_(parent_view) {}

  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
  CefRefPtr<CefKeyboardHandler> GetKeyboardHandler() override { return this; }
  CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }
  CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }

  // The frontend's ready marker (devtools_ready.h): it reported loadCompleted and drew a frame since. Not logged.
  bool OnConsoleMessage(CefRefPtr<CefBrowser> browser, cef_log_severity_t, const CefString& message, const CefString&,
                        int) override {
    if (!IsDevToolsReadyMessage(message.ToString())) return false;
    RevealDevTools(browser);
    return true;
  }

  void OnLoadEnd(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, int) override {
    if (!frame || !frame->IsMain()) return;
    if (docked_) {
      // Relay the frontend's loadCompleted (devtools_ready.h); a frontend that never reports shows after the backstop.
      frame->ExecuteJavaScript(DevToolsReadyScript(), "devtools://cmux/frontend-ready", 0);
      CefPostDelayedTask(TID_UI, base::BindOnce(&RevealDevTools, browser), kDevToolsRevealBackstopMs);
    }
    loaded_frontends().insert(inspected_);
    auto it = pending_panels().find(inspected_);
    if (it != pending_panels().end()) {
      SelectPanel(browser, it->second, true);
      pending_panels().erase(it);
    }
  }

  void OnLoadError(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, ErrorCode, const CefString&,
                   const CefString&) override {
    if (frame && frame->IsMain()) RevealDevTools(browser);
  }

  void OnAfterCreated(CefRefPtr<CefBrowser> browser) override {
    // BROWSER VIDEO F1b: until its frontend loaded, a docked (or panel) DevTools paints its document unthemed, white
    // in a dark theme. As Chrome's DevToolsWindow shows DevTools only after loadCompleted, its window stays
    // invisible over the pane's themed ground (the host view under it) until the frontend's ready marker.
    if (docked_) {
      if (NSWindow* window = DevToolsOwnWindow(browser, parent_view_)) {
        [HiddenDevToolsWindows() addObject:window];
        window.alphaValue = 0;
      }
    }
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
      loaded_frontends().erase(inspected_);
      pending_panels().erase(inspected_);
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
  void* parent_view_;  // NSView*, the host view DevTools docks over; nullptr for Chromium's own window
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
  client = new DevToolsClient(inspected, placement.parent_view);
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

int cmux_shim_devtools_show_panel(int browser_id, const char* panel) {
  CefRefPtr<CefBrowser> browser = BrowserById(browser_id);
  CefRefPtr<CefBrowserHost> page = browser ? browser->GetHost() : nullptr;
  if (!page || !IsPanelId(panel)) {
    return 0;
  }
  CefRefPtr<CefBrowser> open = DevToolsOf(browser_id);
  if (open && loaded_frontends().count(browser_id)) {
    SelectPanel(open, panel, false);
    open->GetHost()->SetFocus(true);
    return 1;
  }
  pending_panels()[browser_id] = panel;
  if (!open) {
    page->ShowDevTools(CefWindowInfo(), nullptr, CefBrowserSettings(), CefPoint());
  }
  return 1;
}

void cmux_shim_devtools_set_focus(int browser_id, int focus) {
  if (CefRefPtr<CefBrowser> open = DevToolsOf(browser_id)) {
    open->GetHost()->SetFocus(focus != 0);
  }
}

}  // extern "C"
