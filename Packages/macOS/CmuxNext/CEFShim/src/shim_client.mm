// CefApp (switches, pump scheduling) and the per-window CefClient that turns
// CEF handler callbacks into cmux_shim_event_t for Swift.

#import <AppKit/AppKit.h>

#include "include/cef_devtools_message_observer.h"
#include "include/cef_parser.h"
#include "shim_internal.h"

namespace cmux_shim {

namespace {

class App : public CefApp, public CefBrowserProcessHandler {
 public:
  explicit App(std::vector<std::string> switches) : switches_(std::move(switches)) {}

  CefRefPtr<CefBrowserProcessHandler> GetBrowserProcessHandler() override { return this; }

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
               public CefDevToolsMessageObserver {
 public:
  explicit Client(int request) : request_(request) {}

  CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }
  CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }
  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
  CefRefPtr<CefKeyboardHandler> GetKeyboardHandler() override { return this; }
  CefRefPtr<CefFindHandler> GetFindHandler() override { return this; }
  CefRefPtr<CefContextMenuHandler> GetContextMenuHandler() override { return this; }

  // MARK: Context menu

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
    Emit(CMUX_SHIM_AFTER_CREATED, id, request, window);
  }

  bool OnBeforePopup(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame>, int, const CefString& target_url,
                     const CefString&, WindowOpenDisposition disposition, bool, const CefPopupFeatures&,
                     CefWindowInfo&, CefRefPtr<CefClient>&, CefBrowserSettings&,
                     CefRefPtr<CefDictionaryValue>&, bool*) override {
    // Tabbed windows: new-tab dispositions become tabs of the same Chromium
    // window (OnAfterCreated with request 0), which keeps window.opener.
    // Report the popup so the host can place it.
    Emit(CMUX_SHIM_POPUP, browser->GetIdentifier(), 0, disposition, 0, target_url.ToString());
    return false;
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
    registrations_.erase(id);
    browsers().erase(id);
    Emit(CMUX_SHIM_BEFORE_CLOSE, id);
  }

  // MARK: Display

  void OnAddressChange(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, const CefString& url) override {
    if (frame->IsMain()) {
      Emit(CMUX_SHIM_ADDRESS, browser->GetIdentifier(), 0, 0, 0, url.ToString());
    }
  }

  void OnTitleChange(CefRefPtr<CefBrowser> browser, const CefString& title) override {
    Emit(CMUX_SHIM_TITLE, browser->GetIdentifier(), 0, 0, 0, title.ToString());
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

  // MARK: Find

  void OnFindResult(CefRefPtr<CefBrowser> browser, int identifier, int count, const CefRect&, int active,
                    bool final_update) override {
    int64_t b = static_cast<int64_t>(active) | (static_cast<int64_t>(final_update ? 1 : 0) << 32);
    Emit(CMUX_SHIM_FIND_RESULT, browser->GetIdentifier(), identifier, count, b);
  }

  // MARK: DevTools

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
