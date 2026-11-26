internal import Foundation

/// The v1 line-protocol browser-panel domain (`open_browser` … `is_webview_focused`),
/// lifted byte-faithfully from the former `TerminalController` "Browser Panel
/// Commands" bodies. Replies are the raw legacy `OK …`/`ERROR: …` strings.
extension ControlCommandCoordinator {
    /// Dispatches the v1 browser-panel commands this coordinator owns; returns
    /// `nil` for anything else so the legacy v1 dispatcher can fall through.
    ///
    /// - Parameters:
    ///   - command: The lowercased v1 command token.
    ///   - args: The raw argument remainder of the command line.
    /// - Returns: The raw reply line, or `nil` if not owned here.
    public func handleBrowserPanelV1(command: String, args: String) -> String? {
        switch command {
        case "open_browser":
            return browserPanelOpen(args)
        case "navigate":
            return browserPanelNavigate(args)
        case "browser_back":
            return browserPanelBack(args)
        case "browser_forward":
            return browserPanelForward(args)
        case "browser_reload":
            return browserPanelReload(args)
        case "get_url":
            return browserPanelGetURL(args)
        case "focus_webview":
            return browserPanelFocusWebView(args)
        case "is_webview_focused":
            return browserPanelIsWebViewFocused(args)
        default:
            return nil
        }
    }

    /// The browser-panel-domain view of the seam. Once the integrator adds
    /// ``ControlBrowserPanelContext`` to the ``ControlCommandContext`` umbrella
    /// this cast is statically guaranteed (and may be simplified to `context`);
    /// until then it lets the domain build standalone without touching the
    /// integrator-owned umbrella file.
    var browserPanelContext: (any ControlBrowserPanelContext)? {
        context as? any ControlBrowserPanelContext
    }

    /// The shared disabled-browser fallback: open externally instead (the
    /// legacy `openExternallyWhenBrowserDisabled`, also used by `new_pane` /
    /// `new_surface`).
    func browserPanelOpenExternallyWhenDisabled(rawURL: String? = nil, url: URL?) -> String {
        if let rawURL, url == nil {
            return "ERROR: Invalid URL \(rawURL)"
        }
        guard let url else { return "ERROR: cmux browser is disabled" }
        let opened = browserPanelContext?.controlBrowserPanelOpenURLExternally(url) ?? false
        return opened ? "OK external_browser_disabled \(url.absoluteString)" : "ERROR: Failed to open URL externally"
    }

    /// `open_browser` — create a browser split off the focused panel.
    func browserPanelOpen(_ args: String) -> String {
        guard browserPanelContext?.controlBrowserPanelTabManagerAvailable() ?? false else {
            return "ERROR: TabManager not available"
        }
        let trimmed = args.trimmingCharacters(in: .whitespacesAndNewlines)
        let url: URL? = trimmed.isEmpty ? nil : URL(string: trimmed)
        guard browserPanelContext?.controlBrowserPanelAvailabilityEnabled() ?? false else {
            return browserPanelOpenExternallyWhenDisabled(rawURL: trimmed.isEmpty ? nil : trimmed, url: url)
        }
        guard let browserPanelID = browserPanelContext?.controlBrowserPanelOpen(url: url) else {
            return "ERROR: Failed to create browser panel"
        }
        return "OK \(browserPanelID.uuidString)"
    }

    /// `navigate` — smart-navigate a browser panel.
    func browserPanelNavigate(_ args: String) -> String {
        guard browserPanelContext?.controlBrowserPanelTabManagerAvailable() ?? false else {
            return "ERROR: TabManager not available"
        }
        let parts = args.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return "ERROR: Usage: navigate <panel_id> <url>" }
        guard let panelID = UUID(uuidString: parts[0]),
              browserPanelContext?.controlBrowserPanelNavigate(panelID: panelID, urlString: parts[1]) ?? false else {
            return "ERROR: Panel not found or not a browser"
        }
        return "OK"
    }

    /// `browser_back` — navigate a browser panel back.
    func browserPanelBack(_ args: String) -> String {
        browserPanelSimpleAction(
            args,
            usage: "ERROR: Usage: browser_back <panel_id>"
        ) { context, panelID in
            context.controlBrowserPanelGoBack(panelID: panelID)
        }
    }

    /// `browser_forward` — navigate a browser panel forward.
    func browserPanelForward(_ args: String) -> String {
        browserPanelSimpleAction(
            args,
            usage: "ERROR: Usage: browser_forward <panel_id>"
        ) { context, panelID in
            context.controlBrowserPanelGoForward(panelID: panelID)
        }
    }

    /// `browser_reload` — reload a browser panel.
    func browserPanelReload(_ args: String) -> String {
        browserPanelSimpleAction(
            args,
            usage: "ERROR: Usage: browser_reload <panel_id>"
        ) { context, panelID in
            context.controlBrowserPanelReload(panelID: panelID)
        }
    }

    /// The shared head of the single-panel-argument browser actions: the
    /// TabManager guard, the usage check, the UUID parse, and the shared
    /// `Panel not found or not a browser` failure.
    private func browserPanelSimpleAction(
        _ args: String,
        usage: String,
        action: (any ControlBrowserPanelContext, UUID) -> Bool
    ) -> String {
        guard browserPanelContext?.controlBrowserPanelTabManagerAvailable() ?? false else {
            return "ERROR: TabManager not available"
        }
        let panelArg = args.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !panelArg.isEmpty else { return usage }
        guard let panelID = UUID(uuidString: panelArg),
              let browserPanelContext, action(browserPanelContext, panelID) else {
            return "ERROR: Panel not found or not a browser"
        }
        return "OK"
    }

    /// `get_url` — the browser panel's current URL (empty when none).
    func browserPanelGetURL(_ args: String) -> String {
        guard browserPanelContext?.controlBrowserPanelTabManagerAvailable() ?? false else {
            return "ERROR: TabManager not available"
        }
        let panelArg = args.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !panelArg.isEmpty else { return "ERROR: Usage: get_url <panel_id>" }
        guard let panelID = UUID(uuidString: panelArg),
              let urlString = browserPanelContext?.controlBrowserPanelCurrentURLString(panelID: panelID) else {
            return "ERROR: Panel not found or not a browser"
        }
        return urlString
    }

    /// `focus_webview` — move first responder into the web view.
    func browserPanelFocusWebView(_ args: String) -> String {
        guard browserPanelContext?.controlBrowserPanelTabManagerAvailable() ?? false else {
            return "ERROR: TabManager not available"
        }
        let panelArg = args.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !panelArg.isEmpty else { return "ERROR: Usage: focus_webview <panel_id>" }
        guard let panelID = UUID(uuidString: panelArg) else {
            return "ERROR: Panel not found or not a browser"
        }
        switch browserPanelContext?.controlBrowserPanelFocusWebView(panelID: panelID) ?? .panelNotFound {
        case .panelNotFound:
            return "ERROR: Panel not found or not a browser"
        case .webViewNotInWindow:
            return "ERROR: WebView is not in a window"
        case .webViewHidden:
            return "ERROR: WebView is hidden"
        case .focusDidNotMove:
            return "ERROR: Focus did not move into web view"
        case .focused:
            return "OK"
        }
    }

    /// `is_webview_focused` — whether the web view holds focus.
    func browserPanelIsWebViewFocused(_ args: String) -> String {
        guard browserPanelContext?.controlBrowserPanelTabManagerAvailable() ?? false else {
            return "ERROR: TabManager not available"
        }
        let panelArg = args.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !panelArg.isEmpty else { return "ERROR: Usage: is_webview_focused <panel_id>" }
        guard let panelID = UUID(uuidString: panelArg) else {
            return "ERROR: Panel not found or not a browser"
        }
        switch browserPanelContext?.controlBrowserPanelIsWebViewFocused(panelID: panelID) ?? .panelNotFound {
        case .panelNotFound:
            return "ERROR: Panel not found or not a browser"
        case .focused(let isFocused):
            return isFocused ? "true" : "false"
        }
    }
}
