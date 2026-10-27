import AppKit
import Foundation

/// Sized popups (`window.open` with window features, OAuth sign-in,
/// `chrome.windows.create({type: 'popup'})`) are shown in a floating panel
/// by the host app. A Chromium window shows one tab, so the popup cannot
/// stay a tab of its opener's window (the opener's pane would show the
/// popup, or go blank): it gets a popup host of its own, whose window is
/// created with an about:blank placeholder when the panel first shows the
/// popup; the popup then moves into it (`cmux_tab_move_to_window` keeps the
/// WebContents, so `window.opener` and `postMessage` keep working) and the
/// placeholder closes.
extension CEFPaneHost {
    static let popupPrefix = "popup-"

    var isPopupHost: Bool { key.pane.rawValue.hasPrefix(Self.popupPrefix) }

    /// The first fork API with `cmux_shim_tab_move_to_window`.
    static let tabMoveForkAPI: Int32 = 3

    /// A tab Chromium opened in this window (target=_blank, window.open,
    /// chrome.tabs.create, a window request the fork placed here). It is
    /// handed to the host app through the opener's delegate as `.adoptTab`,
    /// which keeps `window.opener`.
    /// A `.popup` becomes a floating panel page with its own window
    /// (`adoptPopup`); `bounds` are its window features.
    func adoptChromiumTab(browser: Int32, disposition: BrowserNewTabDisposition = .foregroundTab, bounds: CGRect? = nil) {
        // The spare window has no pane to announce it to: the tab that takes it adopts it.
        if isSpare { return runtime.spareWindow.park(browser, in: self, disposition: disposition, bounds: bounds) }
        let opener = visibleTab ?? tabs.last
        if disposition == .popup { return adoptPopup(browser: browser, bounds: bounds, opener: opener) }
        let tab = CEFTab(id: .random(), profile: key.profile, host: self, runtime: runtime)
        // Same window, same store: a popup of a remote machine's localhost
        // page keeps its store and navigation guard.
        tab.machineStore = opener?.machineStore
        tab.navigationGuard = opener?.navigationGuard ?? .none
        tab.isCreationPending = true
        add(tab)
        runtime.register(tab, browser: browser)
        // Opened by a page: past a new tab's first paint (PageBackground), and
        // Chromium, not us, drives its document, so its page area is its own.
        tab.reachedFirstRealPage(settled: true)
        tab.inheritDelegates(from: opener)
        opener?.emit(.adoptTab(tab, disposition))
    }

    /// Chromium inserted popup `browser` into this window as its foreground
    /// tab. It becomes a page of its own popup host (same profile and
    /// store), announced by the opener as `.openPopup`.
    func adoptPopup(browser: Int32, bounds: CGRect?, opener: CEFTab?) {
        let id = BrowserTabID.random()
        let popupKey = CEFPaneKey(pane: BrowserPaneID(rawValue: Self.popupPrefix + id.rawValue),
                                  profile: key.profile, machineKey: key.machineKey, offTheRecord: key.offTheRecord)
        let host = runtime.host(for: popupKey, lifecycleTrace: lifecycleTrace, contextMenus: contextMenus)
        let tab = CEFTab(id: id, profile: key.profile, host: host, runtime: runtime)
        tab.machineStore = opener?.machineStore
        tab.navigationGuard = opener?.navigationGuard ?? .none
        tab.awaitsWindowMove = true
        tab.popupOpenerHost = self
        host.add(tab)
        runtime.register(tab, browser: browser)
        // Opened by a page: past a new tab's first paint (PageBackground), and
        // Chromium, not us, drives its document, so its page area is its own.
        tab.reachedFirstRealPage(settled: true)
        tab.inheritDelegates(from: opener)
        // Chromium made the popup this window's active tab. Show the opener
        // again on the next turn (this may run inside Chromium's tab
        // insertion, which forbids tab strip changes).
        Task { @MainActor [weak self] in self?.reactivateVisibleTab() }
        opener?.emit(.openPopup(tab, BrowserPopupRequest(features: bounds)))
    }

    /// Makes the tab this host shows Chromium's active tab again.
    func reactivateVisibleTab() {
        guard let visible = visibleTab, !visible.awaitsWindowMove, let browser = visible.browserID else { return }
        lastActivated = browser
        _ = runtime.shim?.tabActivate(browser)
    }

    /// The panel shows a popup that is still in its opener's window: create
    /// this host's window with a placeholder (`windowCreated` then moves the
    /// popup in). A live window takes it at once.
    func ensureOwnWindow(for tab: CEFTab) {
        switch window {
        case .live:
            Task { @MainActor [weak self] in self?.movePopupsIn() }
        case .awaitingProfileProxy, .awaitingExtensions, .creating:
            break
        case .none:
            let blank = CEFTab(id: .random(), profile: key.profile, host: self, runtime: runtime)
            blank.machineStore = tab.machineStore
            blank.navigationGuard = tab.navigationGuard
            placeholder = blank
            add(blank)
            ensureCreated(blank)
        }
    }

    /// Moves every popup waiting in its opener's window into this host's
    /// live window, shows the visible one, closes the placeholder, and lets
    /// the openers show their own pages again. A popup that cannot move
    /// (fork without `cmux_tab_move_to_window`, or a move the fork refused)
    /// closes rather than take over its opener's pane. In host mode the move
    /// is a post: its result says it was sent, and TAB_EVENT 2 confirms it.
    func movePopupsIn() {
        guard case .live = window, let shim = runtime.shim, let anchor = anchorBrowser else { return }
        let canMove = runtime.forkAPIVersion >= Self.tabMoveForkAPI
        var openers: [CEFPaneHost] = []
        for tab in tabs where tab.awaitsWindowMove {
            guard let browser = tab.browserID else { continue }
            guard canMove, shim.tabMoveToWindow(browser, anchor, -1) == 1 else {
                runtime.logger.error("CEF popup \(browser) could not move into its own window; closing it")
                tab.close()
                continue
            }
            tab.awaitsWindowMove = false
            if let opener = tab.popupOpenerHost { openers.append(opener) }
        }
        if let visible = visibleTab, !visible.awaitsWindowMove, let browser = visible.browserID {
            lastActivated = browser
            _ = shim.tabActivate(browser)
            // The shown popup names the page window now: its placeholder closes below.
            hostView.layerHosting.pageShown(browser: browser, tabSwitch: visible.takeTabSwitchShow())
            hostView.postGeometryChange()
        }
        if let blank = placeholder, tabs.contains(where: { $0 !== blank && !$0.awaitsWindowMove && $0.browserID != nil }) {
            placeholder = nil
            blank.close()
        }
        for opener in openers { opener.reactivateVisibleTab() }
    }
}
