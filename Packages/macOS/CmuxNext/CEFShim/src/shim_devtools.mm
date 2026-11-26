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
#include "devtools_call_target.h"
#include "devtools_dock_state.h"
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

// Inspected browser id -> the background its next DevTools starts with
// (cmux_shim_devtools_set_background: the pane's theme color).
std::map<int, cef_color_t>& backgrounds() {
  static std::map<int, cef_color_t> map;
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

// DevTools browsers whose own window this file made invisible (by id: no weak reference to a Chromium window
// class, which may refuse one; the window is found again from the browser's view when it is shown).
std::set<int>& HiddenDevTools() {
  static std::set<int> set;
  return set;
}

// The window that shows a DevTools browser's view, or nil (no view yet, or closed).
NSWindow* DevToolsWindowOf(CefRefPtr<CefBrowser> browser) {
  if (!browser) return nil;
  CefWindowHandle handle = browser->GetHost()->GetWindowHandle();
  if (!handle) return nil;
  id object = (__bridge id)handle;
  if (![object isKindOfClass:[NSView class]]) return nil;
  return ((NSView*)object).window;
}

// The DevTools browser's own window (a Chromium child window over the host's parent view); nil when its view sits
// in the parent's own window (never hide that one).
NSWindow* DevToolsOwnWindow(CefRefPtr<CefBrowser> browser, void* parent_view) {
  NSWindow* window = DevToolsWindowOf(browser);
  id parent = parent_view ? (__bridge id)parent_view : nil;
  NSWindow* parent_window = [parent isKindOfClass:[NSView class]] ? ((NSView*)parent).window : nil;
  if (!window || window == parent_window) return nil;
  return window;
}

// Shows a DevTools window kept invisible until its frontend loaded (DevToolsClient). Reads no parent view: the
// backstop runs later, when the host view may be gone; an opaque window (the parent's own) stays as it is.
void RevealDevTools(CefRefPtr<CefBrowser> browser) {
  if (!browser || HiddenDevTools().erase(browser->GetIdentifier()) == 0) return;
  if (NSWindow* window = DevToolsWindowOf(browser)) window.alphaValue = 1;
}

class DevToolsClient : public CefClient, public CefLifeSpanHandler, public CefKeyboardHandler, public CefLoadHandler,
                       public CefDisplayHandler, public CefDevToolsMessageObserver {
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
        HiddenDevTools().insert(browser->GetIdentifier());
        window.alphaValue = 0;
        // A frontend whose renderer ends, or whose load never ends, still shows: the backstop counts from creation
        // too (the load-end backstop below only exists once the load ended).
        CefPostDelayedTask(TID_UI, base::BindOnce(&RevealDevTools, browser), kDevToolsRevealBackstopMs * 3);
      }
    }
    auto& map = devtools_browsers();
    if (map.count(inspected_) == 0) {
      map[inspected_] = browser;
    }
    // Answers to the shim's own calls to the frontend (cmux_shim_devtools_call: a window image's picture of it).
    registration_ = browser->GetHost()->AddDevToolsMessageObserver(this);
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

  bool OnDevToolsMessage(CefRefPtr<CefBrowser> browser, const void* message, size_t message_size) override {
    return ForwardDevToolsMessage(browser->GetIdentifier(), message, message_size);
  }

  void OnDevToolsMethodResult(CefRefPtr<CefBrowser> browser, int message_id, bool success, const void* result,
                              size_t result_size) override {
    std::string json(static_cast<const char*>(result), result_size);
    Emit(CMUX_SHIM_DEVTOOLS_RESULT, browser->GetIdentifier(), message_id, success ? 1 : 0, 0, json);
  }

  void OnBeforeClose(CefRefPtr<CefBrowser> browser) override {
    registration_ = nullptr;
    ForgetDevToolsProtocol(browser->GetIdentifier());
    HiddenDevTools().erase(browser->GetIdentifier());
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
  CefRefPtr<CefRegistration> registration_;  // the frontend's message observer, until it closes
  IMPLEMENT_REFCOUNTING(DevToolsClient);
};

}  // namespace

void PrepareDevToolsPopup(int inspected, CefWindowInfo& window_info, CefRefPtr<CefClient>& client,
                          CefBrowserSettings& settings, bool* use_default_window) {
  // The host decides now (synchronously, from this event) and calls
  // cmux_shim_devtools_set_background and cmux_shim_devtools_set_placement.
  Emit(CMUX_SHIM_DEVTOOLS_WILL_OPEN, inspected);
  // Until its frontend draws, DevTools shows its browser's background. With
  // none of its own Chromium uses CefSettings.background_color from CEF start
  // (the theme the app launched in): a dark block in a light pane (BROWSER
  // VIDEO F1). Like every page of the pane, DevTools starts on its theme color.
  auto color = backgrounds().find(inspected);
  settings.background_color = color != backgrounds().end() && color->second ? color->second : BackgroundColor();
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

CefRefPtr<CefBrowser> DevToolsFrontendById(int browser_id) {
  return DevToolsFrontendIn<CefRefPtr<CefBrowser>>(devtools_browsers(), browser_id);
}

void ForgetDevTools(int inspected) {
  placements().erase(inspected);
  backgrounds().erase(inspected);
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

void cmux_shim_devtools_set_background(int browser_id, unsigned int argb) {
  backgrounds()[browser_id] = static_cast<cef_color_t>(argb);
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

int cmux_shim_devtools_set_frontend_dock_side(int browser_id, int side) {
  // The DevTools frontend keeps its dock side in its own setting (currentDockState, a JSON string in the profile's
  // devtools.preferences dictionary) and applies it when it loads; the fork reports that as a dock-side choice.
  // Chrome keeps one side, the frontend's: write the host's side there before DevTools opens, so the frontend loads
  // on it and never moves DevTools.
  const std::string value = DevToolsDockStateValue(side);
  CefRefPtr<CefBrowser> browser = BrowserById(browser_id);
  CefRefPtr<CefRequestContext> context = browser ? browser->GetHost()->GetRequestContext() : nullptr;
  if (value.empty() || !context) return 0;
  const char* pref = "devtools.preferences";
  if (!context->CanSetPreference(pref)) return 0;
  CefRefPtr<CefValue> current = context->GetPreference(pref);
  CefRefPtr<CefDictionaryValue> prefs = current && current->GetType() == VTYPE_DICTIONARY
                                            ? current->GetDictionary()->Copy(false)
                                            : CefDictionaryValue::Create();
  if (prefs->GetType(kDevToolsDockStateKey) == VTYPE_STRING && prefs->GetString(kDevToolsDockStateKey).ToString() == value) {
    return 1;
  }
  prefs->SetString(kDevToolsDockStateKey, value);
  CefRefPtr<CefValue> updated = CefValue::Create();
  updated->SetDictionary(prefs);
  CefString error;
  return context->SetPreference(pref, updated, error) ? 1 : -1;
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
