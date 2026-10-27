import CmuxNextBrowser
import WebKit

/// The web view the inspector commands (Inspect Element, Toggle Developer
/// Tools, the `devtools.*` set) act on: a browser tab of either engine, or
/// any other `WKWebView` in the app (Markdown, an agent chat, an internal
/// page, a gallery page in a pane).
@MainActor
enum WebInspectorTarget {
    /// A browser tab: Chromium DevTools for `.cef`, Web Inspector for WebKit.
    case browser(any BrowserTab)
    /// A web view that is not a browser tab.
    case webView(WKWebView)

    /// The page's engine; a plain web view is WebKit.
    var engine: BrowserEngineKind {
        switch self {
        case .browser(let tab): tab.engineKind
        case .webView: .webkit
        }
    }

    var isBrowserTab: Bool {
        if case .browser = self { return true }
        return false
    }

    /// The WebKit engine, for Web Inspector: the plain web view, or a WebKit tab's; nil for a
    /// Chromium tab, whose DevTools the tab itself hosts (``BrowserDevToolsHosting``).
    var webKitEngine: WKWebView? {
        switch self {
        case .browser(let tab): (tab as? WebKitTab)?.webView
        case .webView(let webView): webView
        }
    }

    /// Whether `command` can run on this target, with the reason when not.
    func support(for command: WebDevToolsCommand) -> WebDevToolsSupport {
        command.support(on: engine, isBrowserTab: isBrowserTab)
    }
}
