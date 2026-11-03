public import AppKit

/// Retires a page shown through a pane's shared chrome (`BrowserChromeTabState`): the page closes and leaves
/// the chrome's page area; a chrome that shows it now lets it go and stays for the pane's other tabs.
/// (`BrowserPageRetirement` is for a chrome that shows one page only: it retires both.)
public nonisolated struct BrowserTabRetirement: Sendable {
    private let tab: any BrowserTab
    private let state: BrowserChromeTabState

    public init(tab: any BrowserTab, state: BrowserChromeTabState) {
        self.tab = tab
        self.state = state
    }

    /// Final ownership can end on any thread: on main the page leaves at once, else on the main actor next.
    public func retire() {
        if Thread.isMainThread {
            // main-proof: this branch runs synchronously only on the main thread
            MainActor.assumeIsolated { close() }
        } else {
            // task-owner: retains the page and its state until their main-actor retirement finishes
            Task { @MainActor in close() }
        }
    }

    @MainActor private func close() {
        state.loads.stop()
        if let chrome = state.chrome { BrowserChromeTabSwitch(chrome: chrome).release(state) }
        tab.close()
        tab.contentView.removeFromSuperview()
    }
}

extension BrowserChromeTabSwitch {
    /// The tab `state` closes or moves to another pane: the chrome closes what it showed for it (popups, find, its
    /// notice) and lets its page go: it shows an empty page that loads nothing (`DeferredBrowserTab` with no
    /// address), so it neither keeps a closed page alive nor renders a moved one a second time, until its pane binds
    /// the next tab.
    func release(_ state: BrowserChromeTabState) {
        guard chrome.boundState === state else { return }
        chrome.extensionToolbar.hidePopups()
        chrome.pageInfoIfMade?.close()
        chrome.hideNotice()
        // Its cookie import offer goes (a moved tab's shows on its new chrome); one held for another tab stays.
        if let card = chrome.currentCookieImportCard, !card.isHidden || card.heldFor === state { chrome.hideCookieImportOffer() }
        if let find = chrome.pageBars.findBarIfMade { find.isHidden = true }
        state.chrome = nil
        chrome.boundState = nil
        // Nothing of the tab stays: its hooks (closures that may hold its page), its modes, its page.
        let none = BrowserChromeTabState()
        BrowserChromeTabHooks(chrome: chrome, state: none).apply()
        chrome.loads = BrowserPageLoads()
        let blank = DeferredBrowserTab(id: .random(), engine: chrome.tab.engineKind, url: nil, title: nil)
        chrome.toolbarButtons.bind(blank, modes: none.modes)
        chrome.tab = blank
    }
}

extension BrowserChromeTabState {
    /// The address the page was restored at (history records it as restored, not as a new visit).
    public func markRestored(_ url: URL?) {
        loads.markRestored(url)
    }

    /// Shows `asleep`'s address while the tab's page wakes from hibernation (`BrowserChromeView.holdAddress`).
    public func holdAddress(whileWaking asleep: BrowserTabState) {
        if let chrome { chrome.holdAddress(whileWaking: asleep) } else if asleep.url != nil { wakingAddress = asleep }
    }
}
