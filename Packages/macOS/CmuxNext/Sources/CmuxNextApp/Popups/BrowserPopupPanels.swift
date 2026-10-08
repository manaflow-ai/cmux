import AppKit
import CmuxNextBrowser
import CmuxNextDesign

/// The open popup panels: sized `window.open` popups (OAuth, payment) and
/// extension popup windows, each a `BrowserPopupPanel` over its opener's
/// window. Panel pages are never daemon tabs: they are not recorded, not
/// restored and not listed as tabs. A panel closes when its page calls
/// `window.close()`, on an Escape the page did not use, on Cmd-W while it
/// has the keyboard, with its close button, and when its opener's window
/// closes; closing it closes the page.
final class BrowserPopupPanels {
    private let contextMenus: BrowserContextMenuBuilder
    /// The link, image and selection rows for a right-click, by the
    /// opener's tab (`BrowserPageRequests.hitItems`).
    var hitItems: ((BrowserContextMenuTarget, String) -> [NSMenuItem])?

    init(contextMenus: BrowserContextMenuBuilder = .shared) {
        self.contextMenus = contextMenus
    }

    private struct Entry {
        let panel: BrowserPopupPanel
        weak var parent: NSWindow?
        /// The daemon tab whose page opened the popup (its links and nested
        /// popups go to that tab's pane and window).
        let openerKey: String
    }

    /// False in tests: panels are created but never ordered on screen.
    var ordersPanelsIn = true
    private var entries: [ObjectIdentifier: Entry] = [:]
    private var parentObservers: [ObjectIdentifier: any NSObjectProtocol] = [:]

    // MARK: Queries

    func owns(_ page: any BrowserTab) -> Bool { entries[ObjectIdentifier(page)] != nil }

    func panel(for page: any BrowserTab) -> NSPanel? { entries[ObjectIdentifier(page)]?.panel }

    func openerKey(of page: any BrowserTab) -> String? { entries[ObjectIdentifier(page)]?.openerKey }

    /// The popup pages tab `key` opened, at any depth (a popup's popups keep its opener key).
    func pages(openedBy key: String) -> [any BrowserTab] { entries.values.filter { $0.openerKey == key }.map(\.panel.page) }

    var panels: [BrowserPopupPanel] { entries.values.map(\.panel) }

    /// The panel that is `window` or holds it (a Chromium page window is a
    /// child of its panel).
    func panel(containing window: NSWindow?) -> BrowserPopupPanel? {
        guard let window else { return nil }
        return panels.first { $0 === window || window.parent === $0 }
    }

    // MARK: Lifecycle

    /// Shows `page` in a new panel over `parent`, sized and placed from
    /// `request` on `parent`'s screen. Under `CMUX_NEXT_NO_ACTIVATE=1` it is
    /// ordered front without the keyboard; otherwise it becomes key.
    func open(_ page: any BrowserTab, request: BrowserPopupRequest, over parent: NSWindow, openerKey: String) {
        let screen = parent.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? parent.frame
        let primaryHeight = NSScreen.screens.first?.frame.maxY ?? visible.maxY
        let frame = BrowserPopupPanelGeometry.frame(for: request, opener: parent.frame, visibleFrame: visible,
                                                    primaryHeight: primaryHeight, titleHeight: BrowserPopupPanel.titleHeight)
        let panel = BrowserPopupPanel(page: page, frame: frame)
        let id = ObjectIdentifier(page)
        entries[id] = Entry(panel: panel, parent: parent, openerKey: openerKey)
        panel.onEscape = { [weak self, weak page] in
            if let page { self?.close(page) }
        }
        panel.onClose = { [weak self] in self?.panelClosed(id) }
        observeParent(parent)
        parent.addChildWindow(panel, ordered: .above)
        parent.themeScope.adopt(panel)
        guard ordersPanelsIn else { return }
        WindowActivation.show(panel, .raise)
        if panel.isKeyWindow { page.setFocused(true) }
    }

    /// Closes `page`'s panel and the page.
    func close(_ page: any BrowserTab) {
        entries[ObjectIdentifier(page)]?.panel.close()
    }

    func closeAll() {
        for panel in panels { panel.close() }
    }

    private func panelClosed(_ id: ObjectIdentifier) {
        guard let entry = entries.removeValue(forKey: id) else { return }
        entry.parent?.removeChildWindow(entry.panel)
        entry.panel.page.close()
        if let parent = entry.parent, !entries.values.contains(where: { $0.parent === parent }) {
            if let observer = parentObservers.removeValue(forKey: ObjectIdentifier(parent)) {
                NotificationCenter.default.removeObserver(observer)
            }
        }
    }

    /// A closing opener window takes its popups with it.
    private func observeParent(_ parent: NSWindow) {
        let key = ObjectIdentifier(parent)
        guard parentObservers[key] == nil else { return }
        parentObservers[key] = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: parent, queue: nil
        ) { [weak self, weak parent] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                for entry in self.entries.values where entry.parent === parent { entry.panel.close() }
            }
        }
    }

    // MARK: Page intents

    /// Handles an intent of a panel page; returns false for other pages
    /// and for the intents the caller routes through the opener's tab
    /// (links opened in a new tab, downloads).
    func handle(_ page: any BrowserTab, _ intent: BrowserTabIntent) -> Bool {
        guard let entry = entries[ObjectIdentifier(page)] else { return false }
        switch intent {
        case .close, .unhandledEscape:
            close(page)
        case .openPopup(let child, let request):
            guard let parent = entry.parent else {
                child.close()
                return true
            }
            // A popup an agent drives passes that on, as a tab does (BrowserPageRequests).
            if page.isAgentDriven { child.markAgentDriven() }
            open(child, request: request, over: parent, openerKey: entry.openerKey)
        case .contextMenu(let request):
            contextMenus.present(request, in: page.contentView, leading: hitItems?(request.target, entry.openerKey) ?? [])
        case .resizePopup(let request):
            resize(entry, to: request)
        case .activate, .notice, .rerouteStore, .takeFocus, .unhandledKey:
            // A panel has no tab to select, no chrome for notices or an
            // omnibar to take focus, one store, and no page shortcuts.
            break
        case .openURL, .adoptTab, .download:
            // A download joins the App's list through the opener's tab.
            return false
        }
        return true
    }

    /// `chrome.windows.update` bounds: the new content size (the title bar
    /// stays), at the new position when the page gave one, else keeping the
    /// panel's top-left; always inside the screen.
    private func resize(_ entry: Entry, to request: BrowserPopupRequest) {
        let panel = entry.panel
        let screen = panel.screen ?? entry.parent?.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? panel.frame
        let primaryHeight = NSScreen.screens.first?.frame.maxY ?? visible.maxY
        var frame = BrowserPopupPanelGeometry.frame(for: request, opener: entry.parent?.frame ?? panel.frame, visibleFrame: visible,
                                                    primaryHeight: primaryHeight, titleHeight: BrowserPopupPanel.titleHeight)
        if request.origin == nil {
            frame.origin = CGPoint(x: panel.frame.minX, y: panel.frame.maxY - frame.height)
            if visible.width > 0, visible.height > 0 {
                frame.origin.x = min(max(frame.minX, visible.minX), max(visible.maxX - frame.width, visible.minX))
                frame.origin.y = min(max(frame.minY, visible.minY), max(visible.maxY - frame.height, visible.minY))
            }
        }
        panel.setFrame(frame, display: true)
    }
}
