public import Foundation

/// Where a page-requested tab should open.
public nonisolated enum BrowserNewTabDisposition: Hashable, Sendable {
    /// A new selected tab next to the opener (plain `target=_blank`).
    case foregroundTab
    /// A new unselected tab (middle click; Cmd-click with Chrome's mapping).
    case backgroundTab
    /// Where the host puts every link the person opens (cmux's Cmd-click,
    /// `browser.links.cmdClick`; the host's one rule, `layout.linkPlacement`,
    /// the same place a terminal's Cmd-click lands).
    case linkPlacement
    /// `window.open` with window features (OAuth, payment popups). Callers may
    /// show it as a tab or a small floating pane; it keeps `window.opener`.
    case popup
    /// Shift-click, "Open Link in New Window": a new cmux window (a new
    /// workspace holding the tab).
    case newWindow
}

/// Requests a tab sends to its host. The App layer turns them into daemon
/// commands (create tab, close tab) or UI (downloads list).
public enum BrowserTabIntent {
    /// Open `url` in a new tab. No opener relationship.
    case openURL(URL, BrowserNewTabDisposition)
    /// Insert an already-created tab. Used when the page needs the returned
    /// window object (`window.opener`), so the engine must create the tab
    /// synchronously. The host must insert or close it.
    case adoptTab(any BrowserTab, BrowserNewTabDisposition)
    /// Show an already-created page in a floating popup panel over the
    /// opener's window (`window.open` with window features). The page keeps
    /// `window.opener`. The host must show or close it.
    case openPopup(any BrowserTab, BrowserPopupRequest)
    /// The page called `window.close()`.
    case close
    /// A download started. Observe the object for progress.
    case download(BrowserDownload)
    /// The engine made this tab its window's active tab on its own (an
    /// extension called `chrome.tabs.update({active: true})`). The host
    /// selects it.
    case activate
    /// The page's context menu (Chromium's model with extension items). The
    /// host shows it, adding its own items, and completes the request; a host
    /// that ignores the intent drops the request, which dismisses the menu.
    case contextMenu(BrowserContextMenuRequest)
    /// A one-line message for the user about this tab (the host shows it
    /// over the page), e.g. why a link did not open.
    case notice(String)
    /// A main-frame navigation to `url` would leave the tab's store (a
    /// remote machine's loopback origin, or the reverse); the engine
    /// cancelled it. The host re-creates the tab in the other store with
    /// `url` (plans/cmux-next/remote-localhost.md section 3).
    case rerouteStore(URL)
    /// The tab handed off a main-frame navigation to the local file `url`
    /// (`LocalFileHandoff`) and stayed where it was. The host opens the file
    /// in cmux's markdown page or a WebKit tab.
    case openLocalFile(URL)
    /// The page did not handle an Escape key down (a popup panel closes on
    /// it; a tab ignores it).
    case unhandledEscape
    /// The page did not handle a letter key while no editable field had
    /// focus (Chromium only). The host may run a single-key shortcut on it.
    case unhandledKey(BrowserPageKey)
    /// Keyboard focus left the page: Tab past its last element (`forward`)
    /// or Shift-Tab past its first. The host moves focus to the tab's
    /// omnibar.
    case takeFocus(forward: Bool)
    /// The page showed a web notification its site may show (WebKit:
    /// `new Notification(...)` with notifications allowed). The host shows
    /// a banner and runs `notification.click` when it is clicked.
    case webNotification(BrowserWebNotification)
    /// The page asked for protected media (a Widevine key system) that this engine cannot serve
    /// (``BrowserProtectedMedia``). The host may reopen the tab in WebKit.
    case protectedMediaUnavailable(BrowserProtectedMedia)
    /// The page's popup window asked for a new size or position
    /// (`chrome.windows.update` with bounds). A popup panel follows; a tab
    /// ignores it.
    case resizePopup(BrowserPopupRequest)
    /// The top frame shows a page that waits for a verification email (its detector,
    /// `VerificationPageScripts`, saw a one-time-code field or "we sent you a code" text).
    /// The host's `VerificationAutofillCoordinator` may offer that site's code.
    case verificationPageWaiting
    /// A design mode message from the top frame's isolated world (`BrowserDesignModeScript`):
    /// the runtime's `{type, ...}` as JSON. The host's design mode controller reads it.
    case designMode(Data)
}

/// Receives intents from a tab.
public protocol BrowserTabDelegate: AnyObject {
    func browserTab(_ tab: any BrowserTab, didRequest intent: BrowserTabIntent)
}
