import CmuxBrowser

extension BrowserCrashLog {
    /// The app's crash log: every browser content and helper process that
    /// ended unexpectedly this run (`debug.browser.crashes`). Holds no URLs.
    @MainActor static let app = BrowserCrashLog()
}
