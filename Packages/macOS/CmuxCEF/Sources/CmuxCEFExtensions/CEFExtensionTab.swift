public import CmuxBrowser

/// A Chromium tab that extension calls can target by its browser id.
@MainActor
public protocol CEFExtensionTab: BrowserExtensionTab {
    /// Chromium's browser id, nil before the page is created or after it closed.
    var cefBrowserID: Int32? { get }
}
