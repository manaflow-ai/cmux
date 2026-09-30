import AppKit
import CmuxNextBrowser

/// The open popup panels (sized `window.open` popups).
final class BrowserPopupPanels {
    /// False in tests: panels are created but never ordered on screen.
    var ordersPanelsIn = true

    func open(_ page: any BrowserTab, request: BrowserPopupRequest, over parent: NSWindow, openerKey: String) {}

    func panel(for page: any BrowserTab) -> NSPanel? { nil }

    func owns(_ page: any BrowserTab) -> Bool { false }

    func openerKey(of page: any BrowserTab) -> String? { nil }

    /// Handles an intent of a panel page. Returns false for other pages.
    func handle(_ page: any BrowserTab, _ intent: BrowserTabIntent) -> Bool { false }

    func closeAll() {}
}
