import AppKit

extension PageWebView {
    /// Whether the page's view takes the keys now (nil: always, the default). The browser toolbar
    /// page sets it: the window makes a clicked view first responder only when it accepts, so a press
    /// on a toolbar button leaves the keys on the browser page, and only the omnibar field takes them.
    public var acceptsKeyFocus: (() -> Bool)? {
        get { webView.acceptsKeyFocus }
        set { webView.acceptsKeyFocus = newValue }
    }

    /// Called each time the page's view stops being first responder (a click on the browser page,
    /// a tab switch): the toolbar's field ends editing (`controlTextDidEndEditing`).
    public var onResignedKeys: (() -> Void)? {
        get { webView.onResignedFirstResponder }
        set { webView.onResignedFirstResponder = newValue }
    }
}
