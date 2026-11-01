// CefApp (switches, pump scheduling) and the per-window CefClient that turns
// CEF handler callbacks into cmux_shim_event_t for Swift.

#import <AppKit/AppKit.h>

#include "include/cef_devtools_message_observer.h"
#include "include/cef_drag_handler.h"
#include "include/cef_jsdialog_handler.h"
#include "include/cef_parser.h"
#include "include/cef_resource_request_handler.h"
#include "command_line_apply.h"
#include "artifact_page.h"
#include "external_url.h"
#include "local_file_handoff.h"
#include "local_file_scope.h"
#include "page_scheme_registration.h"
#include "shim_internal.h"

// Every cmux_shim_event_kind_t value is distinct and every enumerator is
// listed: -Wswitch as an error refuses a duplicate case value (two events
// given one number) and a missing enumerator (an event added to the header
// but not here). Compile-time only; never called.
#pragma clang diagnostic push
#pragma clang diagnostic error "-Wswitch"
[[maybe_unused]] static constexpr bool CmuxShimEventKindsAreDistinct(cmux_shim_event_kind_t kind) {
  switch (kind) {
    case CMUX_SHIM_CONTEXT_INITIALIZED:
    case CMUX_SHIM_AFTER_CREATED:
    case CMUX_SHIM_BEFORE_CLOSE:
    case CMUX_SHIM_ADDRESS:
    case CMUX_SHIM_TITLE:
    case CMUX_SHIM_FAVICON:
    case CMUX_SHIM_LOADING_STATE:
    case CMUX_SHIM_LOAD_START:
    case CMUX_SHIM_LOAD_END:
    case CMUX_SHIM_LOAD_ERROR:
    case CMUX_SHIM_PROGRESS:
    case CMUX_SHIM_FULLSCREEN:
    case CMUX_SHIM_DEVTOOLS_RESULT:
    case CMUX_SHIM_FIND_RESULT:
    case CMUX_SHIM_CLOSE_REQUESTED:
    case CMUX_SHIM_TAB_EVENT:
    case CMUX_SHIM_POPUP:
    case CMUX_SHIM_REPLY:
    case CMUX_SHIM_CONTEXT_MENU:
    case CMUX_SHIM_DEVTOOLS_WILL_OPEN:
    case CMUX_SHIM_DEVTOOLS_OPENED:
    case CMUX_SHIM_DEVTOOLS_CLOSED:
    case CMUX_SHIM_RENDER_TERMINATED:
    case CMUX_SHIM_RENDER_UNRESPONSIVE:
    case CMUX_SHIM_RENDER_RESPONSIVE:
    case CMUX_SHIM_CHROME_COMMAND:
    case CMUX_SHIM_NAVIGATION_REROUTE:
    case CMUX_SHIM_KEY_UNHANDLED:
    case CMUX_SHIM_INSTALL_PROMPT:
    case CMUX_SHIM_OMNIBOX_SUGGESTIONS:
    case CMUX_SHIM_TAKE_FOCUS:
    case CMUX_SHIM_DEVTOOLS_EVENT:
    case CMUX_SHIM_PREF_CHANGED:
    case CMUX_SHIM_DOWNLOAD_STARTED:
    case CMUX_SHIM_DOWNLOAD_PROGRESS:
    case CMUX_SHIM_DOWNLOAD_DONE:
    case CMUX_SHIM_AUTH_CALLBACK:
    case CMUX_SHIM_LOCAL_FILE_HANDOFF:
    case CMUX_SHIM_BOOKMARKS_EVENT:
    case CMUX_SHIM_EXTERNAL_URL:
    case CMUX_SHIM_PERMISSION_PROMPT:
    case CMUX_SHIM_PERMISSION_DISMISSED:
    case CMUX_SHIM_PASSWORD_PROMPT:
    case CMUX_SHIM_BEFORE_UNLOAD_DIALOG:
    case CMUX_SHIM_BEFORE_UNLOAD_DISMISSED:
    case CMUX_SHIM_PAGE_RESOURCE:
    case CMUX_SHIM_PAGE_DRAG_ENTER:
    case CMUX_SHIM_FILE_DIALOG:
      return true;
  }
  return false;
}
#pragma clang diagnostic pop

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
    for (const std::string& name : ApplySwitches(command_line, switches_)) {
      NSLog(@"cmux: Chromium switch refused (weakens the sandbox): %s", name.c_str());
    }
  }

  void OnContextInitialized() override {
    InstallForkObserver();
    InstallWindowRequestHandler();
    InstallExtensionUIHandlers();
    InstallPasswordPromptHandler();
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

// A file: page's subresources and subframes outside its folder never load
// (local_file_scope.h, cx-ary1f).
class LocalFileRefusal : public CefResourceRequestHandler {
 public:
  cef_return_value_t OnBeforeResourceLoad(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>, CefRefPtr<CefRequest>,
                                          CefRefPtr<CefCallback>) override {
    return RV_CANCEL;
  }

  IMPLEMENT_REFCOUNTING(LocalFileRefusal);
};

// The URL of the document a request loads into: a subframe's parent for a
// subframe navigation, otherwise the frame itself. An about:blank or
// about:srcdoc frame shares its parent's origin, so its parent decides; with
// no such parent (a popup a page wrote into) the URL is "", which the policy
// refuses.
std::string RequestDocumentURL(CefRefPtr<CefFrame> frame, CefRefPtr<CefRequest> request) {
  if (request->GetResourceType() == RT_SUB_FRAME) frame = frame->GetParent();
  while (frame) {
    std::string url = frame->GetURL().ToString();
    if (!url.empty() && url.compare(0, 6, "about:") != 0) return url;
    frame = frame->GetParent();
  }
  return std::string();
}

// Inspect the whole ancestry: blank/srcdoc children cannot shed the offline
// document's restrictions by inheriting an ancestor's ordinary page URL.
bool RestrictedArtifactFrame(CefRefPtr<CefFrame> frame) {
  while (frame) {
    CefRefPtr<CefFrame> parent = frame->GetParent();
    if (ArtifactContextRestricted(frame->GetURL().ToString(), parent ? parent->GetURL().ToString() : "")) return true;
    frame = parent;
  }
  return false;
}

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
               public CefJSDialogHandler,
               public CefDragHandler,
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
  // beforeunload only; alert, confirm and prompt keep Chromium's dialogs.
  CefRefPtr<CefJSDialogHandler> GetJSDialogHandler() override { return this; }
  CefRefPtr<CefDragHandler> GetDragHandler() override { return this; }
  // File choosers go to the host app (shim_file_dialog.mm).
  CefRefPtr<CefDialogHandler> GetDialogHandler() override { return FileDialogHandlerInstance(); }
  // Every download waits for the host's path (shim_downloads.mm).
  CefRefPtr<CefDownloadHandler> GetDownloadHandler() override { return DownloadHandler(); }
  // Location requests ask in the host's prompt bar (shim_permissions.mm).
  CefRefPtr<CefPermissionHandler> GetPermissionHandler() override { return PermissionHandler(); }

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

  // MARK: Drags

  // A drag of files from outside entered the page: the host learns their
  // paths (a page sees only File objects), so a cmux page can hand a drop
  // to the host the way its WebKit view does (PAGE_DRAG_ENTER). The page
  // still gets the drag.
  bool OnDragEnter(CefRefPtr<CefBrowser> browser, CefRefPtr<CefDragData> drag, DragOperationsMask) override {
    if (!drag || !drag->IsFile()) return false;
    std::vector<CefString> names;
    if (!drag->GetFilePaths(names) || names.empty()) return false;
    CefRefPtr<CefListValue> list = CefListValue::Create();
    for (size_t i = 0; i < names.size(); ++i) list->SetString(i, names[i]);
    CefRefPtr<CefValue> value = CefValue::Create();
    value->SetList(list);
    Emit(CMUX_SHIM_PAGE_DRAG_ENTER, browser->GetIdentifier(), 0, 0, 0, CefWriteJSON(value, JSON_WRITER_DEFAULT).ToString());
    return false;
  }

  // MARK: beforeunload

  // Chromium's own beforeunload dialog is app-modal (AppModalDialogManager)
  // and its Stay button sends -cancelTerminate: to NSApp, which only
  // Chrome's application class answers (the 2026-10-20 nightly crash). The
  // host asks in the tab instead (BEFORE_UNLOAD_DIALOG) and answers with
  // cmux_shim_before_unload_reply. A host close never asks: it leaves.
  bool OnBeforeUnloadDialog(CefRefPtr<CefBrowser> browser, const CefString&, bool is_reload,
                            CefRefPtr<CefJSDialogCallback> callback) override {
    const int id = browser->GetIdentifier();
    if (IsHostClose(id)) {
      callback->Continue(true, CefString());
      return true;
    }
    Emit(CMUX_SHIM_BEFORE_UNLOAD_DIALOG, id, StoreBeforeUnloadCallback(id, callback), is_reload ? 1 : 0);
    return true;
  }

  // Chromium dropped the page's dialogs (a crash, a navigation, the close):
  // a question still waiting goes away unanswered.
  void OnResetDialogState(CefRefPtr<CefBrowser> browser) override {
    if (DropBeforeUnload(browser->GetIdentifier())) Emit(CMUX_SHIM_BEFORE_UNLOAD_DISMISSED, browser->GetIdentifier());
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
                      bool user_gesture, bool is_redirect) override {
    CefRefPtr<CefFrame> parent = frame->GetParent();
    if (RestrictedArtifactFrame(frame) ||
        ArtifactNavigationRefused(frame->IsMain(), frame->GetURL().ToString(),
                                  parent ? parent->GetURL().ToString() : "", request->GetURL().ToString())) return true;
    if (!frame->IsMain()) return false;
    int id = browser->GetIdentifier();
    std::string url = request->GetURL().ToString();
    // A sign-in tab's callback never loads: the session ends with its URL.
    if (NavigationIsAuthCallback(id, url)) {
      Emit(CMUX_SHIM_AUTH_CALLBACK, id, 0, is_redirect ? 1 : 0, 0, url);
      return true;
    }
    // An agent-driven tab never commits a Chromium page (passwords.md, section 2).
    if (NavigationRefusedForAgent(id, url)) return true;
    if (cmux_shim::CEFHandsOffLocalFile(url)) {
      Emit(CMUX_SHIM_LOCAL_FILE_HANDOFF, id, 0, 0, 0, url);
      return true;
    }
    if (IsExternalAppURL(url)) {
      Emit(CMUX_SHIM_EXTERNAL_URL, id, 0, user_gesture && !is_redirect ? 1 : 0, 0, url);
      return true;
    }
    if (!NavigationViolatesGuard(id, url)) return false;
    Emit(CMUX_SHIM_NAVIGATION_REROUTE, id, 0, is_redirect ? 1 : 0, 0, url);
    return true;
  }

  // MARK: Chrome Web Store, local file scope

  CefRefPtr<CefResourceRequestHandler> GetResourceRequestHandler(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame> frame,
                                                                 CefRefPtr<CefRequest> request, bool, bool,
                                                                 const CefString&, bool&) override {
    const std::string url = request->GetURL().ToString();
    const auto type = request->GetResourceType();
    if (RestrictedArtifactFrame(frame) &&
        !ArtifactResourceAllowed(url, type == RT_IMAGE || type == RT_MEDIA || type == RT_FONT_RESOURCE)) {
      static CefRefPtr<CefResourceRequestHandler> refusal = new LocalFileRefusal();
      return refusal;
    }
    // A request with no frame (a worker, a CefURLRequest) has no folder to
    // judge it by: its file: loads are refused.
    if (LocalFileSchemeURL(url) && request->GetResourceType() != RT_MAIN_FRAME &&
        !LocalFileSubresourceAllowed(frame ? RequestDocumentURL(frame, request) : std::string(), url)) {
      static CefRefPtr<CefResourceRequestHandler> refusal = new LocalFileRefusal();
      return refusal;
    }
    return WebStoreRequestHandler(url);
  }

  // MARK: Certificate errors

  // A main-frame certificate error shows Chromium's own interstitial, as in
  // Chrome (Lawrence 2026-10-13); the load error is marked
  // chromium_interstitial so the host shows no page over it. In an
  // agent-driven tab the load fails and the host shows its own warning
  // instead; a Proceed a person pressed there (cmux_shim_certificate_proceed)
  // continues, or leaves the decision to the interstitial (a named host,
  // HSTS): an agent could then press the interstitial's Proceed too, which
  // is accepted, since a person consented first.
  bool OnCertificateError(CefRefPtr<CefBrowser> browser, cef_errorcode_t cert_error, const CefString& request_url,
                          CefRefPtr<CefSSLInfo>, CefRefPtr<CefCallback> callback) override {
    CefURLParts parts;
    const std::string host = CefParseURL(request_url, parts) ? CefString(&parts.host).ToString() : std::string();
    switch (TakeCertificateProceed(browser->GetIdentifier(), host, cert_error)) {
      case CertificateProceed::kContinue:
        callback->Continue();
        return true;
      case CertificateProceed::kChromium:
        NoteCertificateError(browser->GetIdentifier(), cert_error, true);
        return false;
      case CertificateProceed::kNone:
        if (BrowserIsAgentDriven(browser->GetIdentifier())) {
          // An agent could press Proceed in Chromium's interstitial (its
          // page script): the host's warning, whose Proceed only a person
          // can press, shows instead.
          NoteCertificateError(browser->GetIdentifier(), cert_error, false);
          callback->Cancel();
          return true;
        }
        // Chromium's own interstitial, as in Chrome (Lawrence 2026-10-13).
        NoteCertificateError(browser->GetIdentifier(), cert_error, true);
        return false;
    }
    return false;
  }

  // MARK: Renderer process failures

  // The host shows its own "sad tab" in the pane and reloads from it; Chrome
  // style would otherwise draw Chromium's Aw, Snap! page in the page window.
  void OnRenderProcessTerminated(CefRefPtr<CefBrowser> browser, TerminationStatus status, int error_code,
                                 const CefString& error_string) override {
    int id = browser->GetIdentifier();
    TakeUnresponsiveCallback(id);
    // A crash cancels dialogs without OnResetDialogState: the question goes too.
    if (DropBeforeUnload(id)) Emit(CMUX_SHIM_BEFORE_UNLOAD_DISMISSED, id);
    CancelFileDialogs(id);
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
      // Chromium keeps hidden rows in the model (an extension item with
      // visible: false); the host drops them as Chrome's menu does.
      item->SetBool("visible", model->IsVisibleAt(i));
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
    DropBeforeUnload(id);
    CancelFileDialogs(id);
    TakeHostClose(id);
    ForgetNavigationGuard(id);
    ForgetCertificateState(id);
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
      ForgetCertificateState(browser->GetIdentifier());
      // a = 1 when the committed entry came from a POST (a form; a 303 after
      // it is a GET entry): such a page never hibernates (BR-R1).
      CefRefPtr<CefNavigationEntry> entry = browser->GetHost()->GetVisibleNavigationEntry();
      int64_t from_post = entry && entry->IsValid() && entry->HasPostData() ? 1 : 0;
      Emit(CMUX_SHIM_LOAD_START, browser->GetIdentifier(), 0, from_post, 0, frame->GetURL().ToString());
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
      std::string error_text = text.ToString();
      bool chromium_interstitial = false;
      const int error = CertificateLoadError(browser->GetIdentifier(), code, &error_text, &chromium_interstitial);
      Emit(CMUX_SHIM_LOAD_ERROR, browser->GetIdentifier(), 0, error, chromium_interstitial ? 1 : 0, error_text,
           url.ToString());
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

  // After the renderer: a key the page did not handle. A Command or Control
  // chord goes to the host first, which runs a shortcut it held back for the
  // page (cmux Find when the page has no search of its own) and then stops
  // it here. A plain Escape is reported (a popup panel closes on it), and so
  // is a letter, with or without Shift, while no editable field has focus
  // (single-key page shortcuts such as link hints). Everything else goes on
  // to Chromium's own accelerators.
  bool OnKeyEvent(CefRefPtr<CefBrowser> browser, const CefKeyEvent& event, CefEventHandle os_event) override {
    constexpr int kEscape = 0x1B;
    constexpr uint32_t kModifiers = EVENTFLAG_SHIFT_DOWN | EVENTFLAG_CONTROL_DOWN | EVENTFLAG_ALT_DOWN |
                                    EVENTFLAG_COMMAND_DOWN;
    constexpr uint32_t kChordModifiers = EVENTFLAG_CONTROL_DOWN | EVENTFLAG_ALT_DOWN | EVENTFLAG_COMMAND_DOWN;
    if (event.type != KEYEVENT_RAWKEYDOWN) {
      return false;
    }
    Host& h = host();
    if (h.unhandled_key && os_event && (event.modifiers & (EVENTFLAG_COMMAND_DOWN | EVENTFLAG_CONTROL_DOWN)) &&
        h.unhandled_key(h.ctx, browser->GetIdentifier(), (__bridge void*)os_event) != 0) {
      return true;
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
