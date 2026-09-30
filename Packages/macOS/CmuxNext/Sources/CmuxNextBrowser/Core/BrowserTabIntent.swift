public import Foundation

/// Where a page-requested tab should open.
public nonisolated enum BrowserNewTabDisposition: Hashable, Sendable {
    /// A new selected tab next to the opener (plain `target=_blank`).
    case foregroundTab
    /// A new unselected tab (Cmd-click, middle click).
    case backgroundTab
    /// `window.open` with window features (OAuth, payment popups). Callers may
    /// show it as a tab or a small floating pane; it keeps `window.opener`.
    case popup
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
    /// The page did not handle an Escape key down (a popup panel closes on
    /// it; a tab ignores it).
    case unhandledEscape
    /// The page's popup window asked for a new size or position
    /// (`chrome.windows.update` with bounds). A popup panel follows; a tab
    /// ignores it.
    case resizePopup(BrowserPopupRequest)
}

/// Receives intents from a tab.
public protocol BrowserTabDelegate: AnyObject {
    func browserTab(_ tab: any BrowserTab, didRequest intent: BrowserTabIntent)
}
