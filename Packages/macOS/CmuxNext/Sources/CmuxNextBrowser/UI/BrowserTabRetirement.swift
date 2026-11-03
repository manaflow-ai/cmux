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
        if let chrome = state.chrome { BrowserChromeTabSwitch(chrome: chrome).release(state) }
        tab.close()
        tab.contentView.removeFromSuperview()
    }
}

extension BrowserChromeTabSwitch {
    /// The tab `state` closes: the chrome closes what it showed for it (popups, find, its notice) and shows no
    /// tab until its pane binds the next one.
    func release(_ state: BrowserChromeTabState) {
        guard chrome.boundState === state else { return }
        chrome.extensionToolbar.hidePopups()
        chrome.pageInfoIfMade?.close()
        chrome.hideNotice()
        chrome.hideCookieImportOffer()
        if let find = chrome.pageBars.findBarIfMade { find.isHidden = true }
        state.chrome = nil
        chrome.boundState = nil
    }
}

extension BrowserChromeView {
    /// The tab state this chrome shows now (`bind(_:state:)`), nil while it shows none.
    public var shownTabState: BrowserChromeTabState? { boundState }
}

extension BrowserChromeTabState {
    /// The address the page was restored at (history records it as restored, not as a new visit).
    public func markRestored(_ url: URL?) {
        if let chrome { chrome.markRestored(url) } else if let url, recordedURL == nil { recordedURL = url }
    }

    /// Shows `asleep`'s address while the tab's page wakes from hibernation (`BrowserChromeView.holdAddress`).
    public func holdAddress(whileWaking asleep: BrowserTabState) {
        if let chrome { chrome.holdAddress(whileWaking: asleep) } else if asleep.url != nil { wakingAddress = asleep }
    }
}
