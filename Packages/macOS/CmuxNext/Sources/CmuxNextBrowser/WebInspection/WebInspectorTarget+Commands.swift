import AppKit
import WebKit

/// Developer tools for the target (Cmd-Opt-I, Cmd-Opt-J, Cmd-Opt-C). Chromium tabs and cmux pages
/// in Chromium show DevTools in their own view (`BrowserDevToolsHosting`); WebKit web views show
/// Safari's Web Inspector (``WebKitInspector``), which every build allows; other engines only open
/// their DevTools.
extension WebInspectorTarget {
    /// Opens the developer tools when closed, closes them when open.
    public func toggle() {
        if let devTools = devToolsHost { return devTools.performDevTools(.toggle) }
        guard let webView = webKitView else { return fallback() }
        WebKitInspector(webView: webView).toggle()
    }

    /// Opens the developer tools on their console.
    public func showConsole() {
        if let devTools = devToolsHost { return devTools.performDevTools(.console) }
        guard let webView = webKitView else { return fallback() }
        WebKitInspector(webView: webView).show(.console)
    }

    /// Chromium's element picker; WebKit shows its inspector and starts element selection.
    public func inspectElement() {
        if let devTools = devToolsHost { return devTools.performDevTools(.inspectElement) }
        guard let webView = webKitView else { return fallback() }
        WebKitInspector(webView: webView).inspectElement()
    }

    private func fallback() {
        if case .browser(let tab) = self { tab.showDevTools() }
    }
}
