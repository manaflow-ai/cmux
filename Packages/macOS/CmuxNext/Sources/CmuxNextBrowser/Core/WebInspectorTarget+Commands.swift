// Developer tools for the focused web view (Cmd-Opt-I, Cmd-Opt-J, Cmd-Opt-C) and whether they show.
extension WebInspectorTarget {
    /// Whether the target's developer tools show (Toggle Developer Tools' palette state): Chromium's
    /// DevTools state, else WebKit's Web Inspector. Cheap and makes no web view inspectable.
    public var isInspectorOpen: Bool {
        if case .browser(let tab) = self, let devTools = tab as? any BrowserDevToolsHosting { return devTools.devTools.isOpen }
        return webKitView.map { WebKitInspector(webView: $0).isOpen } ?? false
    }

    /// Opens the developer tools when closed, closes them when open.
    public func toggleInspector() {
        if case .browser(let tab) = self, let devTools = tab as? any BrowserDevToolsHosting { return devTools.performDevTools(.toggle) }
        guard let webView = webKitView else { return fallback() }
        WebKitInspector(webView: webView).toggle()
    }

    /// Shows the developer tools on their console.
    public func showConsole() {
        if case .browser(let tab) = self, let devTools = tab as? any BrowserDevToolsHosting { return devTools.performDevTools(.console) }
        guard let webView = webKitView else { return fallback() }
        WebKitInspector(webView: webView).show(.console)
    }

    /// Chromium's element picker; WebKit shows its inspector and starts element selection.
    public func inspectElement() {
        if case .browser(let tab) = self, let devTools = tab as? any BrowserDevToolsHosting {
            return devTools.performDevTools(.inspectElement)
        }
        guard let webView = webKitView else { return fallback() }
        WebKitInspector(webView: webView).inspectElement()
    }

    private func fallback() {
        if case .browser(let tab) = self { tab.showDevTools() }
    }
}
