public import AppKit
public import CmuxNextBrowser
public import CmuxNextDesign

/// The open popup windows: sized `window.open` popups (OAuth, payment) and
/// extension popup windows, each a `BrowserPopupWindow` of its own, like
/// Chrome's `TYPE_POPUP` browser windows. Popup pages are never daemon
/// tabs: they are not recorded, not restored and not listed as tabs. A
/// popup closes when its page calls `window.close()`, on Cmd-W while it has
/// the keyboard, and with its close button; closing it closes the page. It
/// stays open when its opener's window closes (Chrome closes no popup with
/// its opener), and Escape never closes it.
public final class BrowserPopupWindows {
    private let contextMenus: BrowserContextMenuBuilder
    /// The app's ``ActiveLookScope``, for every popup's backdrop.
    private let activeLook: ActiveLookScope?
    /// The link, image and selection rows for a right-click, by the
    /// opener's tab (`BrowserPageRequests.hitItems`).
    public var hitItems: ((BrowserContextMenuTarget, String) -> [NSMenuItem])?

    /// The omnibar suggestion engine for a popup page (its profile's, as a
    /// tab's omnibar has); nil gives the popup a fresh engine.
    public var suggestionEngine: ((any BrowserTab) -> OmniboxSuggestionEngine?)?

    public init(contextMenus: BrowserContextMenuBuilder = .shared, activeLook: ActiveLookScope?) {
        self.contextMenus = contextMenus
        self.activeLook = activeLook
    }

    private struct Entry {
        let window: BrowserPopupWindow
        /// The cmux window that showed the opener's tab (gone after it closes).
        weak var opener: NSWindow?
        /// The daemon tab whose page opened the popup (its links and nested
        /// popups go to that tab's pane and window).
        let openerKey: String
    }

    /// False in tests: windows are created but never ordered on screen.
    public var ordersWindowsIn = true
    private var entries: [ObjectIdentifier: Entry] = [:]

    // MARK: Queries

    public func owns(_ page: any BrowserTab) -> Bool { entries[ObjectIdentifier(page)] != nil }

    public func window(for page: any BrowserTab) -> BrowserPopupWindow? { entries[ObjectIdentifier(page)]?.window }

    public func openerKey(of page: any BrowserTab) -> String? { entries[ObjectIdentifier(page)]?.openerKey }

    /// The popup pages tab `key` opened, at any depth (a popup's popups keep its opener key).
    public func pages(openedBy key: String) -> [any BrowserTab] { entries.values.filter { $0.openerKey == key }.map(\.window.page) }

    public var windows: [BrowserPopupWindow] { entries.values.map(\.window) }

    /// The popup window that is `window` or holds it (a Chromium page window
    /// is a child of its popup window).
    public func window(containing window: NSWindow?) -> BrowserPopupWindow? {
        guard let window else { return nil }
        return windows.first { $0 === window || window.parent === $0 }
    }

    /// The cmux window whose tab opened `popup`, while it is open.
    public func openerWindow(of popup: BrowserPopupWindow) -> NSWindow? {
        guard let opener = entries[ObjectIdentifier(popup.page)]?.opener, opener.isVisible || opener.isMiniaturized else { return nil }
        return opener
    }

    // MARK: Lifecycle

    /// Shows `page` in a new popup window, sized and placed from `request`
    /// on `opener`'s screen. Under `CMUX_NEXT_NO_ACTIVATE=1` it is ordered
    /// front without the keyboard; otherwise it becomes key (Chrome
    /// activates every popup that passed the popup blocker).
    public func open(_ page: any BrowserTab, request: BrowserPopupRequest, from opener: NSWindow, openerKey: String) {
        let screen = opener.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? opener.frame
        let primaryHeight = NSScreen.screens.first?.frame.maxY ?? visible.maxY
        let request = BrowserPopupWindowGeometry.droppingChromiumDefaultOrigin(request, visibleFrame: visible, primaryHeight: primaryHeight)
        let frame = BrowserPopupWindowGeometry.frame(for: request, opener: opener.frame, fallbackContent: opener.frame.size,
                                                     visibleFrame: visible, primaryHeight: primaryHeight,
                                                     chromeHeight: BrowserPopupWindow.chromeHeight)
        let window = BrowserPopupWindow(page: page, frame: frame, suggestionEngine: suggestionEngine?(page) ?? OmniboxSuggestionEngine(),
                                        activeLook: activeLook)
        let id = ObjectIdentifier(page)
        // A popup's own popups keep the cmux window of the first opener.
        let cmuxOpener = (opener as? BrowserPopupWindow).flatMap { entries[ObjectIdentifier($0.page)]?.opener } ?? opener
        entries[id] = Entry(window: window, opener: cmuxOpener, openerKey: openerKey)
        window.onClose = { [weak self] in self?.windowClosed(id) }
        opener.themeScope.adopt(window)
        guard ordersWindowsIn else { return }
        WindowActivation.show(window, .raise)
        if window.isKeyWindow { page.setFocused(true) }
    }

    /// Closes `page`'s window and the page.
    public func close(_ page: any BrowserTab) {
        entries[ObjectIdentifier(page)]?.window.close()
    }

    public func closeAll() {
        for window in windows { window.close() }
    }

    private func windowClosed(_ id: ObjectIdentifier) {
        guard let entry = entries.removeValue(forKey: id) else { return }
        entry.window.page.close()
    }

    // MARK: Page intents

    /// Handles an intent of a popup page; returns false for other pages
    /// and for the intents the caller routes through the opener's tab
    /// (links opened in a new tab, downloads).
    public func handle(_ page: any BrowserTab, _ intent: BrowserTabIntent) -> Bool {
        guard let entry = entries[ObjectIdentifier(page)] else { return false }
        switch intent {
        case .close:
            close(page)
        case .unhandledEscape:
            // Chrome's Escape stops a load; it never closes a popup.
            entry.window.cancelOperation(nil)
        case .openPopup(let child, let request):
            // A popup an agent drives passes that on, as a tab does (BrowserPageRequests).
            if page.isAgentDriven { child.markAgentDriven() }
            // Placed from the popup that opened it, as Chrome cascades from
            // the last active window.
            open(child, request: request, from: entry.window, openerKey: entry.openerKey)
        case .contextMenu(let request):
            contextMenus.present(request, in: page.contentView, leading: hitItems?(request.target, entry.openerKey) ?? [])
        case .resizePopup(let request):
            resize(entry, to: request)
        case .activate, .notice, .rerouteStore, .takeFocus, .unhandledKey, .verificationPageWaiting, .designMode, .protectedMediaUnavailable:
            // A popup has no tab to select, no chrome for notices or an
            // editable omnibar to take focus, one store, no page shortcuts, no prompt
            // bar for a verification code offer, and no tab to reopen in WebKit
            // (its opener's engine holds `window.opener`).
            break
        case .openURL, .adoptTab, .download, .openLocalFile, .webNotification:
            // A download joins the App's list through the opener's tab, a
            // handed-off file opens in the opener's pane, and a notification
            // is the opener tab's.
            return false
        }
        return true
    }

    /// `window.resizeTo`/`moveTo` and `chrome.windows.update` bounds: the new
    /// page size (the title bar and location bar stay), at the new position
    /// when the page gave one, else keeping the window's top-left; always
    /// inside the screen.
    private func resize(_ entry: Entry, to request: BrowserPopupRequest) {
        let window = entry.window
        let screen = window.screen ?? entry.opener?.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? window.frame
        let primaryHeight = NSScreen.screens.first?.frame.maxY ?? visible.maxY
        let chrome = BrowserPopupWindow.chromeHeight
        let current = CGSize(width: window.frame.width, height: max(window.frame.height - chrome, 0))
        var placed = request
        if placed.origin == nil {
            // Keep the top-left: measured from the primary display's top.
            placed.origin = CGPoint(x: window.frame.minX, y: primaryHeight - window.frame.maxY)
        }
        let frame = BrowserPopupWindowGeometry.frame(for: placed, opener: window.frame, fallbackContent: current,
                                                     visibleFrame: visible, primaryHeight: primaryHeight, chromeHeight: chrome)
        window.setFrame(frame, display: true)
    }
}
