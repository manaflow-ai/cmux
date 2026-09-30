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
}

/// Receives intents from a tab.
public protocol BrowserTabDelegate: AnyObject {
    func browserTab(_ tab: any BrowserTab, didRequest intent: BrowserTabIntent)
}
