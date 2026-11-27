import AppKit

/// Retires a page before AppKit destroys its chrome. Chromium's hidden-ancestor
/// callbacks must never encounter a deallocating ancestor while registering weak observers.
public nonisolated struct BrowserPageRetirement: Sendable {
    private let tab: any BrowserTab
    private let chrome: BrowserChromeView

    public init(tab: any BrowserTab, chrome: BrowserChromeView) {
        self.tab = tab
        self.chrome = chrome
    }

    /// Final ownership can end on any thread. Keep both objects alive until their
    /// main-actor cleanup finishes; on main, detach before the caller releases them.
    public func retire() {
        if Thread.isMainThread {
            // main-proof: this branch runs synchronously only on the main thread
            MainActor.assumeIsolated { close() }
        } else {
            // task-owner: retains the page and chrome until their main-actor retirement finishes
            Task { @MainActor in close() }
        }
    }

    @MainActor private func close() {
        tab.close()
        tab.contentView.removeFromSuperview()
        // Page Info and the Extensions bubble keep their panels between opens: they close for good.
        chrome.closePopupPanels()
        chrome.removeFromSuperview()
    }
}
