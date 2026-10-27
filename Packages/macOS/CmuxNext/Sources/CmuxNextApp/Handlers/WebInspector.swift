import AppKit
import CmuxNextBrowser
import WebKit

/// Developer tools for the focused web view (Cmd-Opt-I, Cmd-Opt-J, Cmd-Opt-C):
/// a browser tab of either engine or any other `WKWebView` (`WebInspectorTarget`).
/// Chromium tabs show DevTools docked in the pane (`BrowserDevToolsHosting`);
/// a target's WebKit engine (`WebInspectorTarget.webKitEngine`) shows Safari's
/// Web Inspector (`WebKitInspector`), which every build allows; other engines
/// only open their DevTools.
enum WebInspector {
    static func toggle(_ target: WebInspectorTarget) {
        if case .browser(let tab) = target, let devTools = tab as? any BrowserDevToolsHosting { return devTools.performDevTools(.toggle) }
        guard let webKit = target.webKitEngine else { return fallback(target) }
        WebKitInspector(webView: webKit).toggle()
    }

    static func showConsole(_ target: WebInspectorTarget) {
        if case .browser(let tab) = target, let devTools = tab as? any BrowserDevToolsHosting { return devTools.performDevTools(.console) }
        guard let webKit = target.webKitEngine else { return fallback(target) }
        WebKitInspector(webView: webKit).show(.console)
    }

    /// Chromium's element picker; WebKit shows its inspector and starts element selection.
    static func inspectElement(_ target: WebInspectorTarget) {
        if case .browser(let tab) = target, let devTools = tab as? any BrowserDevToolsHosting {
            return devTools.performDevTools(.inspectElement)
        }
        guard let webKit = target.webKitEngine else { return fallback(target) }
        WebKitInspector(webView: webKit).inspectElement()
    }

    private static func fallback(_ target: WebInspectorTarget) {
        if case .browser(let tab) = target { tab.showDevTools() }
    }
}
