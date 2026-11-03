public import WebKit

/// The web view the inspector commands (Inspect Element, Toggle Developer Tools, the `devtools.*`
/// set) act on: a browser tab of either engine, or any other `WKWebView` in the app (Markdown, an
/// agent chat, an internal page, a gallery page in a pane).
///
/// Chromium tabs show DevTools docked in the pane (``BrowserDevToolsHosting``); WebKit web views
/// show Safari's Web Inspector (``WebKitInspector``), which every build allows; other engines only
/// open their DevTools.
///
/// ```swift
/// WebInspectorTarget.browser(tab).toggleInspector()
/// ```
@MainActor
public enum WebInspectorTarget {
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

    /// The WebKit web view, for Web Inspector: the plain one, or a WebKit tab's.
    public var webKitView: WKWebView? {
        switch self {
        case .browser(let tab): (tab as? WebKitTab)?.webView
        case .webView(let webView): webView
        }
    }

    /// Whether `command` can run on this target, with the reason when not.
    ///
    /// - Parameter command: The `devtools.*` command.
    /// - Returns: Supported, or the limit that keeps it from running here.
    public func support(for command: WebDevToolsCommand) -> WebDevToolsSupport {
        command.support(on: engine, isBrowserTab: isBrowserTab)
    }
}
