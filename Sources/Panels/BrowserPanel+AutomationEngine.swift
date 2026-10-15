import CmuxBrowser
import Foundation

extension BrowserPanel {
    /// The engine page browser automation drives when this panel does not
    /// render with WebKit; nil for a WebKit panel, which automation keeps
    /// driving through its `WKWebView` paths unchanged.
    ///
    /// The single seam between socket automation and the panel's engine: the
    /// engine integration returns the panel's Chromium `BrowserPage` here.
    var automationEnginePage: (any BrowserPage)? {
        nil
    }

    /// The engine this panel renders with, as browser automation reports it.
    var automationEngineKind: BrowserEngineKind {
        automationEnginePage?.engineKind ?? .webkit
    }
}
