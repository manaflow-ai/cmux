public import WebKit

extension WKNavigationType {
    /// Whether a `targetFrame == nil` navigation of this type should fall back to
    /// opening in a new tab.
    ///
    /// Scripted popups (`.other`) rely on `WKUIDelegate.createWebViewWith`
    /// returning a live web view so `window.opener`/`postMessage` remain intact
    /// across OAuth flows, so only non-`.other` navigations fall back here.
    public var fallsBackNilTargetToNewTab: Bool {
        self != .other
    }
}
