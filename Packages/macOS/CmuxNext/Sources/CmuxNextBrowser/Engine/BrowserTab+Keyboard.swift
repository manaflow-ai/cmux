public import AppKit

extension BrowserTab {
    /// Whether this page holds the keyboard of `window`: the first responder is in its view, or, for a page drawn
    /// in its own child window (`.childWindow`, a Chromium page), the key window is a child of `window`.
    ///
    /// - Parameter keyWindow: The app's key window (`NSApp.keyWindow`); a seam for tests.
    public func holdsKeyboard(in window: NSWindow, keyWindow: NSWindow?) -> Bool {
        if let view = window.firstResponder as? NSView, view.isDescendant(of: contentView) { return true }
        return presentation == .childWindow && keyWindow?.parent === window
    }
}
