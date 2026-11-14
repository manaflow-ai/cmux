public import WebKit

/// The web view the inspector commands (Inspect Element, Toggle Developer Tools, the `devtools.*`
/// set) act on: a browser tab of either engine, or one of cmux's own pages (Markdown, an agent
/// chat, Home, Settings, a gallery page in a pane) in WebKit or in Chromium.
///
/// ```swift
/// let target = WebInspectorTarget.chromiumPage(pageTab)
/// target.toggle() // Chromium DevTools, docked as the person last placed them
/// ```
@MainActor
public enum WebInspectorTarget {
    /// A browser tab: Chromium DevTools for `.cef`, Web Inspector for WebKit.
    case browser(any BrowserTab)
    /// A web view that is not a browser tab (a cmux page in WebKit).
    case webView(WKWebView)
    /// A cmux page shown in Chromium (the agent chat's default engine): its page tab opens
    /// Chromium DevTools. It is no browser tab.
    case chromiumPage(CEFTab)

    /// The page's engine; a plain web view is WebKit.
    public var engine: BrowserEngineKind {
        switch self {
        case .browser(let tab): tab.engineKind
        case .webView: .webkit
        case .chromiumPage(let tab): tab.engineKind
        }
    }

    /// Whether the target is a browser tab (the commands that need one are disabled otherwise).
    public var isBrowserTab: Bool {
        if case .browser = self { return true }
        return false
    }

    /// The WebKit web view, for Web Inspector: the plain one, or a WebKit tab's.
    public var webKitView: WKWebView? {
        switch self {
        case .browser(let tab): (tab as? WebKitTab)?.webView
        case .webView(let webView): webView
        case .chromiumPage: nil
        }
    }

    /// The Chromium tab, for Chromium DevTools: a Chromium browser tab or a cmux page's tab.
    public var chromiumTab: CEFTab? {
        switch self {
        case .browser(let tab): tab as? CEFTab
        case .webView: nil
        case .chromiumPage(let tab): tab
        }
    }

    /// The tab whose DevTools open in its own view: a browser tab that hosts them, or a cmux page's
    /// Chromium tab.
    public var devToolsHost: (any BrowserDevToolsHosting)? {
        switch self {
        case .browser(let tab): tab as? any BrowserDevToolsHosting
        case .webView: nil
        case .chromiumPage(let tab): tab
        }
    }

    /// Whether `command` can run on this target, with the reason when not.
    ///
    /// - Parameter command: A Developer Tools command.
    /// - Returns: Supported, or the limit that stops it.
    public func support(for command: WebDevToolsCommand) -> WebDevToolsSupport {
        command.support(on: engine, isBrowserTab: isBrowserTab)
    }
}
