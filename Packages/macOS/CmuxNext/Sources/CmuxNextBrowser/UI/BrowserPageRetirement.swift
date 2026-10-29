import AppKit

/// Retires a page before AppKit destroys its chrome. Chromium's hidden-ancestor
/// callbacks must never encounter a deallocating ancestor while registering weak observers.
public enum BrowserPageRetirement {
    /// Final ownership can end on any thread. Keep both objects alive until their
    /// main-actor cleanup finishes; on main, detach before the caller releases them.
    public nonisolated static func retire(_ tab: any BrowserTab, chrome: BrowserChromeView) {
        if Thread.isMainThread {
            // main-proof: this branch runs synchronously only on the main thread
            MainActor.assumeIsolated { close(tab, chrome: chrome) }
        } else {
            // task-owner: retains the page and chrome until their main-actor retirement finishes
            Task { @MainActor in close(tab, chrome: chrome) }
        }
    }

    private static func close(_ tab: any BrowserTab, chrome: BrowserChromeView) {
        tab.close()
        tab.contentView.removeFromSuperview()
        chrome.removeFromSuperview()
    }
}
