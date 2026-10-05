// CefApp (switches, pump scheduling) and the per-window CefClient that turns
// CEF handler callbacks into cmux_shim_event_t for Swift.

#import <AppKit/AppKit.h>

#include "include/cef_devtools_message_observer.h"
#include "include/cef_parser.h"
#include "page_scheme_registration.h"
#include "shim_internal.h"

namespace cmux_shim {

namespace {

class App : public CefApp, public CefBrowserProcessHandler {
 public:
  explicit App(std::vector<std::string> switches) : switches_(std::move(switches)) {}

  CefRefPtr<CefBrowserProcessHandler> GetBrowserProcessHandler() override { return this; }

  // The helper processes register the same schemes (helper_main.mm).
  void OnRegisterCustomSchemes(CefRawPtr<CefSchemeRegistrar> registrar) override {
    RegisterCustomSchemes(registrar);
  }

  void OnBeforeCommandLineProcessing(const CefString& process_type,
                                     CefRefPtr<CefCommandLine> command_line) override {
    if (!process_type.empty()) {
      return;
    }
    for (const std::string& entry : switches_) {
      size_t eq = entry.find('=');
      if (eq == std::string::npos) {
        command_line->AppendSwitch(entry);
      } else {
        command_line->AppendSwitchWithValue(entry.substr(0, eq), entry.substr(eq + 1));
      }
    }
  }

  void OnContextInitialized() override {
    InstallForkObserver();
    InstallWindowRequestHandler();
    InstallExtensionUIHandlers();
    InstallPageSchemes();
    Emit(CMUX_SHIM_CONTEXT_INITIALIZED, 0);
  }

  // Browsers Chromium creates in a window the host did not create
  // (chrome.windows.create, tabs.create with no window) report through
  // this client with request 0, so the host can move them into a pane.
  CefRefPtr<CefClient> GetDefaultClient() override { return DefaultClient(); }

  void OnScheduleMessagePumpWork(int64_t delay_ms) override {
    Host& h = host();
    if (h.schedule) {
      h.schedule(h.ctx, delay_ms);
    }
  }

 private:
  std::vector<std::string> switches_;
  IMPLEMENT_REFCOUNTING(App);
};

class Client : public CefClient,
               public CefDisplayHandler,
               public CefLoadHandler,
               public CefLifeSpanHandler,
               public CefKeyboardHandler,
               public CefFindHandler,
               public CefContextMenuHandler,
               public CefRequestHandler,
               public CefCommandHandler,
               public CefFocusHandler,
               public CefDevToolsMessageObserver {
 public:
  explicit Client(int request) : request_(request) {}

  CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }
  CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }
  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
  CefRefPtr<CefKeyboardHandler> GetKeyboardHandler() override { return this; }
  CefRefPtr<CefFindHandler> GetFindHandler() override { return this; }
  CefRefPtr<CefContextMenuHandler> GetContextMenuHandler() override { return this; }
  CefRefPtr<CefRequestHandler> GetRequestHandler() override { return this; }
  CefRefPtr<CefCommandHandler> GetCommandHandler() override { return this; }
  CefRefPtr<CefFocusHandler> GetFocusHandler() override { return this; }
  // Every download waits for the host's path (shim_downloads.mm).
  CefRefPtr<CefDownloadHandler> GetDownloadHandler() override { return DownloadHandler(); }

  // MARK: Focus

  // CEF focuses a page after every navigation it starts (a new browser's
  // first load, LoadURL); on macOS that activates the page window, which
  // takes the keys from the host's omnibar. The host decides every
  // request (its focus coordinator is the only owner of focus); returning
  // true cancels it.
  bool OnSetFocus(CefRefPtr<CefBrowser> browser, FocusSource source) override {
    const Host& h = host();
    if (!h.focus_request) {
      return false;
    }
    return h.focus_request(h.ctx, browser->GetIdentifier(), source) == 0;
  }

  // Tab past the last element or Shift-Tab past the first: the host moves
  // focus to its omnibar.
  void OnTakeFocus(CefRefPtr<CefBrowser> browser, bool next) override {
    Emit(CMUX_SHIM_TAKE_FOCUS, browser->GetIdentifier(), 0, next ? 1 : 0);
  }

  // MARK: Chromium commands

  // Chromium commands that open a window of Chromium's own never run: the
  // host sees them as CHROME_COMMAND. Every other command runs normally.
  bool OnChromeCommand(CefRefPtr<CefBrowser> browser, int command_id, cef_window_open_disposition_t) override {
    if (!IsWindowCommand(command_id)) {
      return false;
    }
    Emit(CMUX_SHIM_CHROME_COMMAND, browser->GetIdentifier(), command_id);
    return true;
  }

  // MARK: Remote localhost

  // A main-frame navigation that would leave its store (a loopback origin of
  // a remote machine, or the reverse) is cancelled; the host re-creates the
  // tab in the other store with the same URL.
  bool OnBeforeBrowse(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, CefRefPtr<CefRequest> request,
                      bool, bool is_redirect) override {
    if (!frame->IsMain()) return false;
    int id = browser->GetIdentifier();
    std::string url = request->GetURL().ToString();
    // An agent-driven tab never commits a Chromium page (passwords.md, section 2).
    if (NavigationRefusedForAgent(id, url)) return true;
    if (!NavigationViolatesGuard(id, url)) return false;
    Emit(CMUX_SHIM_NAVIGATION_REROUTE, id, 0, is_redirect ? 1 : 0, 0, url);
    return true;
  }

  // MARK: Chrome Web Store

  CefRefPtr<CefResourceRequestHandler> GetResourceRequestHandler(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>,
                                                                 CefRefPtr<CefRequest> request, bool, bool,
                                                                 const CefString&, bool&) override {
    return WebStoreRequestHandler(request->GetURL().ToString());
  }

  // MARK: Renderer process failures

  // The host shows its own "sad tab" in the pane and reloads from it; Chrome
  // style would otherwise draw Chromium's Aw, Snap! page in the page window.
  void OnRenderProcessTerminated(CefRefPtr<CefBrowser> browser, TerminationStatus status, int error_code,
                                 const CefString& error_string) override {
    int id = browser->GetIdentifier();
    TakeUnresponsiveCallback(id);
    Emit(CMUX_SHIM_RENDER_TERMINATED, id, 0, status, error_code, error_string.ToString());
  }

  // Returning true keeps Chromium's hung-page dialog away: the host shows
  // "Page unresponsive" in the pane and answers through
  // cmux_shim_unresponsive_reply.
  bool OnRenderProcessUnresponsive(CefRefPtr<CefBrowser> browser,
                                   CefRefPtr<CefUnresponsiveProcessCallback> callback) override {
    int id = browser->GetIdentifier();
    StoreUnresponsiveCallback(id, callback);
    Emit(CMUX_SHIM_RENDER_UNRESPONSIVE, id);
    return true;
  }

  void OnRenderProcessResponsive(CefRefPtr<CefBrowser> browser) override {
    int id = browser->GetIdentifier();
    TakeUnresponsiveCallback(id);
    Emit(CMUX_SHIM_RENDER_RESPONSIVE, id);
  }

  // MARK: Context menu

  // Link items that open a Chromium window (a new window, another profile's
  // window, an app window, a split view in the hidden tab strip) are
  // removed. "Open Link in New Tab" stays: it opens a cmux tab. "Open Link
  // in Incognito Window" stays: its OFF_THE_RECORD request reaches the
  // window request handler, and cmux opens a cmux incognito window.
  void OnBeforeContextMenu(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>, CefRefPtr<CefContextMenuParams>,
                           CefRefPtr<CefMenuModel> model) override {
    for (int command : {50101 /* IDC_CONTENT_CONTEXT_OPENLINKNEWWINDOW */,
                        50108 /* IDC_CONTENT_CONTEXT_OPENLINKINPROFILE */,
                        50109 /* IDC_CONTENT_CONTEXT_OPENLINKBOOKMARKAPP */,
                        50111 /* IDC_CONTENT_CONTEXT_OPENLINKSPLITVIEW */,
                        50113 /* IDC_CONTENT_CONTEXT_OPENLINK_ISOLATED */}) {
      while (model->Remove(command)) {
      }
    }
    RemoveDoubleSeparators(model);
  }

  static void RemoveDoubleSeparators(CefRefPtr<CefMenuModel> model) {
    bool previous_separator = true;  // no separator first
    for (size_t i = 0; i < model->GetCount();) {
      const bool separator = model->GetTypeAt(i) == MENUITEMTYPE_SEPARATOR;
      if (separator && previous_separator) {
        model->RemoveAt(i);
        continue;
      }
      previous_separator = separator;
      ++i;
    }
    if (model->GetCount() > 0 && model->GetTypeAt(model->GetCount() - 1) == MENUITEMTYPE_SEPARATOR) {
      model->RemoveAt(model->GetCount() - 1);
    }
  }

  // Chromium's page menu (extension chrome.contextMenus items included) is
  // shown by the host as its own menu, merged with host actions.
  bool RunContextMenu(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
                      CefRefPtr<CefContextMenuParams> params, CefRefPtr<CefMenuModel> model,
                      CefRefPtr<CefRunContextMenuCallback> callback) override {
    CefRefPtr<CefValue> items = CefValue::Create();
    items->SetList(MenuItems(model));
    CefRefPtr<CefDictionaryValue> info = CefDictionaryValue::Create();
    info->SetString("link_url", params->GetLinkUrl());
    info->SetString("source_url", params->GetSourceUrl());
    info->SetString("page_url", params->GetPageUrl());
    info->SetString("selection", params->GetSelectionText());
    info->SetBool("editable", params->IsEditable());
    info->SetInt("media_type", params->GetMediaType());
    CefRefPtr<CefValue> infoValue = CefValue::Create();
    infoValue->SetDictionary(info);
    int token = StoreMenuCallback(callback);
    Emit(CMUX_SHIM_CONTEXT_MENU, browser->GetIdentifier(), token, params->GetXCoord(), params->GetYCoord(),
         CefWriteJSON(items, JSON_WRITER_DEFAULT).ToString(), CefWriteJSON(infoValue, JSON_WRITER_DEFAULT).ToString());
    return true;
  }

  static CefRefPtr<CefListValue> MenuItems(CefRefPtr<CefMenuModel> model) {
    CefRefPtr<CefListValue> list = CefListValue::Create();
    for (size_t i = 0; i < model->GetCount(); ++i) {
      CefRefPtr<CefDictionaryValue> item = CefDictionaryValue::Create();
      item->SetInt("id", model->GetCommandIdAt(i));
      item->SetString("label", model->GetLabelAt(i));
      item->SetBool("enabled", model->IsEnabledAt(i));
      item->SetBool("checked", model->IsCheckedAt(i));
      switch (model->GetTypeAt(i)) {
        case MENUITEMTYPE_SEPARATOR: item->SetString("type", "separator"); break;
        case MENUITEMTYPE_CHECK: item->SetString("type", "check"); break;
        case MENUITEMTYPE_RADIO: item->SetString("type", "radio"); break;
        case MENUITEMTYPE_SUBMENU:
          item->SetString("type", "submenu");
          if (CefRefPtr<CefMenuModel> sub = model->GetSubMenuAt(i)) item->SetList("items", MenuItems(sub));
          break;
        default: item->SetString("type", "command"); break;
      }
      list->SetDictionary(list->GetSize(), item);
    }
    return list;
  }

  // MARK: Life span

  void OnAfterCreated(CefRefPtr<CefBrowser> browser) override {
    int id = browser->GetIdentifier();
    browsers()[id] = browser;
    registrations_[id] = browser->GetHost()->AddDevToolsMessageObserver(this);
    int request = request_;
    request_ = 0;
    int window = fork_api().tab_window_id ? fork_api().tab_window_id(id) : 0;
    std::string features;
    std::string popup_url;
    int64_t popup = request == 0 ? TakePopup(browser, &features, &popup_url) : 0;
    Emit(CMUX_SHIM_AFTER_CREATED, id, request, window, popup, features, popup_url);
  }

  bool OnBeforePopup(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame>, int popup_id, const CefString& target_url,
                     const CefString&, WindowOpenDisposition disposition, bool user_gesture,
                     const CefPopupFeatures& features,
                     CefWindowInfo& window_info, CefRefPtr<CefClient>&, CefBrowserSettings& settings,
                     CefRefPtr<CefDictionaryValue>&, bool*) override {
    // Every popup (target=_blank, window.open with or without features) is
    // a tab: no parent view or bounds of its own, so Chromium never gives it
    // a window. Fork API 8 adds it to a cmux window (the window request
    // handler places NEW_POPUP/NEW_WINDOW); older forks give it its own
    // Chromium window and the host moves the tab into a pane. window.opener
    // stays either way. AFTER_CREATED carries the disposition and features.
    window_info = CefWindowInfo();
    // A page opened by a page is past a new tab's first paint: Chromium's
    // white default (PageBackground; cmux also sets it on adoption).
    settings.background_color = 0xFFFFFFFF;
    RememberPopup(browser->GetIdentifier(), popup_id, target_url.ToString(), disposition, user_gesture, features);
    Emit(CMUX_SHIM_POPUP, browser->GetIdentifier(), 0, disposition, user_gesture ? 1 : 0, target_url.ToString());
    return false;
  }

  // Chromium refused a popup after OnBeforePopup: it never reaches
  // OnAfterCreated, so it must not be matched to another tab.
  void OnBeforePopupAborted(CefRefPtr<CefBrowser> browser, int popup_id) override {
    AbortPopup(browser->GetIdentifier(), popup_id);
  }

  void OnBeforeDevToolsPopup(CefRefPtr<CefBrowser> browser, CefWindowInfo& window_info, CefRefPtr<CefClient>& client,
                             CefBrowserSettings&, CefRefPtr<CefDictionaryValue>&, bool* use_default_window) override {
    // Every DevTools of this page (ShowDevTools, Chromium's DevTools
    // commands, the context menu's Inspect) gets its own client, so it is
    // never adopted as a tab and never reports this page's URL or title.
    PrepareDevToolsPopup(browser->GetIdentifier(), window_info, client, use_default_window);
  }

  bool DoClose(CefRefPtr<CefBrowser> browser) override {
    int id = browser->GetIdentifier();
    if (!TakeHostClose(id)) {
      Emit(CMUX_SHIM_CLOSE_REQUESTED, id);
    }
    // The embedder owns the parent view; Chromium must not close it.
    return true;
  }

  void OnBeforeClose(CefRefPtr<CefBrowser> browser) override {
    int id = browser->GetIdentifier();
    TakeUnresponsiveCallback(id);
    ForgetNavigationGuard(id);
    registrations_.erase(id);
    ForgetDevToolsProtocol(id);
    browsers().erase(id);
    ForgetOwnBackground(id);
    ForgetDevTools(id);
    ForgetPopups(id);
    Emit(CMUX_SHIM_BEFORE_CLOSE, id);
  }

  // MARK: Display

  void OnAddressChange(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, const CefString& url) override {
    if (frame->IsMain()) {
      Emit(CMUX_SHIM_ADDRESS, browser->GetIdentifier(), 0, 0, 0, DisplayAddress(browser, url.ToString()));
    }
  }

  void OnTitleChange(CefRefPtr<CefBrowser> browser, const CefString& title) override {
    Emit(CMUX_SHIM_TITLE, browser->GetIdentifier(), 0, 0, 0, DisplayTitle(browser, title.ToString()));
  }

  void OnFaviconURLChange(CefRefPtr<CefBrowser> browser, const std::vector<CefString>& urls) override {
    Emit(CMUX_SHIM_FAVICON, browser->GetIdentifier(), 0, 0, 0, urls.empty() ? "" : urls.front().ToString());
  }

  void OnFullscreenModeChange(CefRefPtr<CefBrowser> browser, bool fullscreen) override {
    Emit(CMUX_SHIM_FULLSCREEN, browser->GetIdentifier(), 0, fullscreen ? 1 : 0);
  }

  void OnLoadingProgressChange(CefRefPtr<CefBrowser> browser, double progress) override {
    Emit(CMUX_SHIM_PROGRESS, browser->GetIdentifier(), 0, static_cast<int64_t>(progress * 1000));
  }

  // MARK: Load

  void OnLoadingStateChange(CefRefPtr<CefBrowser> browser, bool loading, bool back, bool forward) override {
    // The tab's Chromium window may not exist in OnAfterCreated or at the
    // first activation; by its first load it does (the fork watches each
    // window once).
    if (fork_api().side_panel_watch) fork_api().side_panel_watch(browser->GetIdentifier());
    Emit(CMUX_SHIM_LOADING_STATE, browser->GetIdentifier(), 0, (loading ? 1 : 0) | (back ? 2 : 0) | (forward ? 4 : 0));
  }

  void OnLoadStart(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, TransitionType) override {
    if (frame->IsMain()) {
      Emit(CMUX_SHIM_LOAD_START, browser->GetIdentifier(), 0, 0, 0, frame->GetURL().ToString());
    }
  }

  void OnLoadEnd(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, int status) override {
    if (frame->IsMain()) {
      Emit(CMUX_SHIM_LOAD_END, browser->GetIdentifier(), 0, status);
    }
  }

  void OnLoadError(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, ErrorCode code,
                   const CefString& text, const CefString& url) override {
    if (frame->IsMain()) {
      Emit(CMUX_SHIM_LOAD_ERROR, browser->GetIdentifier(), 0, code, 0, text.ToString(), url.ToString());
    }
  }

  // MARK: Keyboard

  bool OnPreKeyEvent(CefRefPtr<CefBrowser> browser, const CefKeyEvent& event, CefEventHandle os_event,
                     bool*) override {
    Host& h = host();
    if (!h.key || !os_event || event.type != KEYEVENT_RAWKEYDOWN) {
      return false;
    }
    return h.key(h.ctx, browser->GetIdentifier(), (__bridge void*)os_event) != 0;
  }

  // After the renderer: a key the page did not handle. A plain Escape is
  // reported (a popup panel closes on it), and so is a letter, with or
  // without Shift, while no editable field has focus (single-key page
  // shortcuts such as link hints). Everything goes on to Chromium's own
  // accelerators.
  bool OnKeyEvent(CefRefPtr<CefBrowser> browser, const CefKeyEvent& event, CefEventHandle) override {
    constexpr int kEscape = 0x1B;
    constexpr uint32_t kModifiers = EVENTFLAG_SHIFT_DOWN | EVENTFLAG_CONTROL_DOWN | EVENTFLAG_ALT_DOWN |
                                    EVENTFLAG_COMMAND_DOWN;
    constexpr uint32_t kChordModifiers = EVENTFLAG_CONTROL_DOWN | EVENTFLAG_ALT_DOWN | EVENTFLAG_COMMAND_DOWN;
    if (event.type != KEYEVENT_RAWKEYDOWN) {
      return false;
    }
    if (event.windows_key_code == kEscape && !(event.modifiers & kModifiers)) {
      Emit(CMUX_SHIM_KEY_UNHANDLED, browser->GetIdentifier(), 0, kEscape);
    } else if (event.windows_key_code >= 'A' && event.windows_key_code <= 'Z' && !(event.modifiers & kChordModifiers) &&
               !event.focus_on_editable_field && !event.is_system_key) {
      const int64_t shift = (event.modifiers & EVENTFLAG_SHIFT_DOWN) ? 1 : 0;
      Emit(CMUX_SHIM_KEY_UNHANDLED, browser->GetIdentifier(), 0, event.windows_key_code, shift);
    }
    return false;
  }

  // MARK: Find

  void OnFindResult(CefRefPtr<CefBrowser> browser, int identifier, int count, const CefRect&, int active,
                    bool final_update) override {
    int64_t b = static_cast<int64_t>(active) | (static_cast<int64_t>(final_update ? 1 : 0) << 32);
    Emit(CMUX_SHIM_FIND_RESULT, browser->GetIdentifier(), identifier, count, b);
  }

  // MARK: DevTools

  // Every message first: raw-send replies are consumed here and never
  // reach OnDevToolsMethodResult; watched events also go to the host.
  bool OnDevToolsMessage(CefRefPtr<CefBrowser> browser, const void* message, size_t message_size) override {
    return ForwardDevToolsMessage(browser->GetIdentifier(), message, message_size);
  }

  void OnDevToolsMethodResult(CefRefPtr<CefBrowser> browser, int message_id, bool success, const void* result,
                              size_t result_size) override {
    std::string json(static_cast<const char*>(result), result_size);
    Emit(CMUX_SHIM_DEVTOOLS_RESULT, browser->GetIdentifier(), message_id, success ? 1 : 0, 0, json);
  }

 private:
  int request_;
  std::map<int, CefRefPtr<CefRegistration>> registrations_;
  IMPLEMENT_REFCOUNTING(Client);
};

}  // namespace

CefRefPtr<CefApp> MakeApp(std::vector<std::string> switches) {
  return new App(std::move(switches));
}

CefRefPtr<CefClient> MakeClient(int request) {
  return new Client(request);
}

CefRefPtr<CefClient> DefaultClient() {
  static CefRefPtr<CefClient> client = new Client(0);
  return client;
}

static std::map<int, CefRefPtr<CefUnresponsiveProcessCallback>>& unresponsive_callbacks() {
  static std::map<int, CefRefPtr<CefUnresponsiveProcessCallback>> map;
  return map;
}

void StoreUnresponsiveCallback(int browser_id, CefRefPtr<CefUnresponsiveProcessCallback> callback) {
  unresponsive_callbacks()[browser_id] = callback;
}

CefRefPtr<CefUnresponsiveProcessCallback> TakeUnresponsiveCallback(int browser_id) {
  auto& map = unresponsive_callbacks();
  auto it = map.find(browser_id);
  if (it == map.end()) return nullptr;
  CefRefPtr<CefUnresponsiveProcessCallback> callback = it->second;
  map.erase(it);
  return callback;
}

static std::map<int, CefRefPtr<CefRunContextMenuCallback>>& menu_callbacks() {
  static std::map<int, CefRefPtr<CefRunContextMenuCallback>> map;
  return map;
}

int StoreMenuCallback(CefRefPtr<CefRunContextMenuCallback> callback) {
  static int next = 1;
  int token = next++;
  menu_callbacks()[token] = callback;
  return token;
}

CefRefPtr<CefRunContextMenuCallback> TakeMenuCallback(int token) {
  auto& map = menu_callbacks();
  auto it = map.find(token);
  if (it == map.end()) return nullptr;
  CefRefPtr<CefRunContextMenuCallback> callback = it->second;
  map.erase(it);
  return callback;
}

}  // namespace cmux_shim
