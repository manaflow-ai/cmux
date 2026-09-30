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
    /// (links opened in a new tab).
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
            open(child, request: request, over: parent, openerKey: entry.openerKey)
        case .contextMenu(let request):
            BrowserContextMenuBuilder.present(request, in: page.contentView)
        case .resizePopup:
            break
        case .activate, .download, .notice, .rerouteStore:
            // A panel has no tab to select, no chrome for notices, and one store.
            break
        case .openURL, .adoptTab:
            return false
        }
        return true
    }

    // MARK: Keys

    /// Cmd-W closes the popup that has the keyboard (its panel, or its
    /// Chromium page window) instead of the opener's tab.
    func interceptKeyDown(_ event: NSEvent, in window: NSWindow?) -> Bool {
        guard let panel = panel(containing: window) else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags == .command, event.charactersIgnoringModifiers?.lowercased() == "w" else { return false }
        close(panel.page)
        return true
    }
}
