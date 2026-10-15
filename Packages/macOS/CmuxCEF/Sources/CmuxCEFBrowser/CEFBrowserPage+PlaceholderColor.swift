public import AppKit
public import CmuxBrowser

extension CEFBrowserPage: BrowserPagePlaceholderColoring {
    /// The host view's color until Chromium's window paints its first frame.
    /// Chromium's own page background is left at its default.
    public var placeholderColor: NSColor {
        get { browser.hostView.placeholderColor }
        set { browser.hostView.placeholderColor = newValue }
    }
}
