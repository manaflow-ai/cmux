import AppKit
import CmuxBrowser

extension BrowserPanel {
    /// The panel's Chromium extension host, or nil for a WebKit panel.
    ///
    /// Chromium pages conform to ``BrowserExtensionHosting``; until the
    /// engine plumbing gives `BrowserPanel` an engine page, every panel is
    /// WebKit and this is nil, so extension commands report that they need
    /// the Chromium engine.
    var extensionHost: (any BrowserExtensionHosting)? {
        extensionHostingPage as? any BrowserExtensionHosting
    }

    /// The engine page that may host extensions. WebKit-only today.
    private var extensionHostingPage: AnyObject? { nil }
}
