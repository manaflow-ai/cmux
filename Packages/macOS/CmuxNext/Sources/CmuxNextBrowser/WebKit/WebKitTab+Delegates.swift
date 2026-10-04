import AppKit
public import Foundation
public import WebKit

// MARK: - Navigation

extension WebKitTab: WKNavigationDelegate {
    public func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        preferences: WKWebpagePreferences,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy, WKWebpagePreferences) -> Void
    ) {
        if navigationAction.shouldPerformDownload {
            decisionHandler(.download, preferences)
            return
        }
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow, preferences)
            return
        }

        let isUserLinkClick = navigationAction.navigationType == .linkActivated
        if isUserLinkClick, Self.isWebScheme(url) {
            switch Self.linkClick(flags: navigationAction.modifierFlags, button: navigationAction.buttonNumber) {
            case .navigate: break
            case .open(let disposition):
                decisionHandler(.cancel, preferences)
                emit(.openURL(url, disposition))
                return
            case .download:
                decisionHandler(.download, preferences)
                return
            }
        }

        if !Self.isWebScheme(url) {
            decisionHandler(.cancel, preferences)
            // Other apps open only from a click in the main frame, never from
            // a script or a redirect.
            if isUserLinkClick, navigationAction.targetFrame?.isMainFrame ?? true {
                NSWorkspace.shared.open(url)
            }
            return
        }
        applySiteSettings(to: preferences, for: navigationAction)
        decisionHandler(.allow, preferences)
    }

    public func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void
    ) {
        let isAttachment = (navigationResponse.response as? HTTPURLResponse)
            .flatMap { $0.value(forHTTPHeaderField: "Content-Disposition") }?
            .lowercased()
            .hasPrefix("attachment") ?? false
        if navigationResponse.isForMainFrame, isAttachment || !navigationResponse.canShowMIMEType {
            decisionHandler(.download)
        } else {
            decisionHandler(.allow)
        }
    }

    public func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        register(download, source: navigationAction.request.url)
    }

    public func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        register(download, source: navigationResponse.response.url)
    }

    public func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard let id = navigationID(for: navigation, creating: true) else { return }
        apply(.started(id, url: webView.url))
    }

    public func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
        guard let id = navigationID(for: navigation, creating: false) else { return }
        apply(.redirected(id, url: webView.url))
    }

    public func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard let id = navigationID(for: navigation, creating: false) else { return }
        apply(.committed(id, url: webView.url))
        pageInfoActivity.documentCommitted(origin: webView.url.flatMap(PageInfoSite.origin(of:)))
        // The title can arrive before the commit (back/forward cache), and
        // the commit clears it, so read the authoritative value again.
        apply(.titleChanged(webView.title))
        syncHistory()
        syncSecurity()
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let id = navigationID(for: navigation, creating: false) else { return }
        forgetNavigation(navigation)
        apply(.finished(id))
        pageDidFinish()
        syncHistory()
        refreshFavicon()
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        guard let id = navigationID(for: navigation, creating: false) else { return }
        forgetNavigation(navigation)
        apply(.failed(id, BrowserLoadError(error)))
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        guard let id = navigationID(for: navigation, creating: false) else { return }
        forgetNavigation(navigation)
        apply(.failed(id, BrowserLoadError(error)))
    }

    /// WebKit gives no reason; the sad tab says the page crashed.
    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        apply(.processExited(BrowserProcessExit(reason: .crashed)))
    }

    /// Where a page-created window goes when a modifier or the link menu
    /// decided it; nil means the page's own request (a tab or a popup).
    func newTabDisposition(for action: WKNavigationAction) -> BrowserNewTabDisposition? {
        if let picked = takeContextMenuDisposition() { return picked }
        if case .open(let disposition) = Self.linkClick(flags: action.modifierFlags, button: action.buttonNumber) { return disposition }
        return nil
    }

    static func isWebScheme(_ url: URL) -> Bool {
        switch url.scheme?.lowercased() {
        case "http", "https", "file", "about", "data", "blob": true
        default: false
        }
    }
}

// MARK: - UI

extension WebKitTab: WKUIDelegate {
    public func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        // Without a host there is nowhere to show the page: block the popup.
        guard hasDelegate, let child = makeChildTab(configuration: configuration) else { return nil }
        if let explicit = newTabDisposition(for: navigationAction) {
            emit(.adoptTab(child, explicit))
        } else if windowFeatures.width != nil || windowFeatures.height != nil {
            // A sized popup (OAuth, payment): a floating panel, with opener.
            let features = CGRect(x: windowFeatures.x?.doubleValue ?? 0, y: windowFeatures.y?.doubleValue ?? 0,
                                  width: windowFeatures.width?.doubleValue ?? 0, height: windowFeatures.height?.doubleValue ?? 0)
            emit(.openPopup(child, BrowserPopupRequest(features: features)))
        } else {
            emit(.adoptTab(child, .foregroundTab))
        }
        return child.webView
    }

    public func webViewDidClose(_ webView: WKWebView) {
        emit(.close)
    }

    public func webView(
        _ webView: WKWebView,
        requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType,
        decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void
    ) {
        let kind: BrowserPermissionKind = switch type {
        case .camera: .camera
        case .microphone: .microphone
        default: .cameraAndMicrophone
        }
        // Stored per-site decisions answer without asking (PageInfo).
        decideMediaCapture(kind, origin: Self.displayOrigin(origin), decisionHandler: decisionHandler)
    }

    public func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor () -> Void
    ) {
        enqueuePrompt(.alert(message: message), origin: Self.displayOrigin(frame.securityOrigin)) { _ in
            completionHandler()
        }
    }

    public func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor (Bool) -> Void
    ) {
        enqueuePrompt(.confirm(message: message), origin: Self.displayOrigin(frame.securityOrigin)) { response in
            completionHandler(response == .accept)
        }
    }

    public func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor (String?) -> Void
    ) {
        enqueuePrompt(
            .textInput(message: prompt, defaultText: defaultText),
            origin: Self.displayOrigin(frame.securityOrigin)
        ) { response in
            if case .text(let text) = response {
                completionHandler(text)
            } else {
                completionHandler(nil)
            }
        }
    }

    public func webView(
        _ webView: WKWebView,
        runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor ([URL]?) -> Void
    ) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        panel.resolvesAliases = true
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            completionHandler(response == .OK ? panel.urls : nil)
        }
        if let window = webView.window {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            panel.begin(completionHandler: finish)
        }
    }

    static func displayOrigin(_ origin: WKSecurityOrigin) -> String {
        guard !origin.host.isEmpty else { return "\(origin.protocol)://" }
        let defaultPort = (origin.protocol == "https" && origin.port == 443) || (origin.protocol == "http" && origin.port == 80)
        let port = origin.port == 0 || defaultPort ? "" : ":\(origin.port)"
        return "\(origin.protocol)://\(origin.host)\(port)"
    }
}

// MARK: - Script messages

extension WebKitTab: WKScriptMessageHandler {
    public func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == PaneFullscreenScript.messageHandlerName,
              message.frameInfo.isMainFrame,
              let on = message.body as? Bool else { return }
        // Entering hides the chrome: only in answer to the user (a script
        // could otherwise hide the address bar and draw a fake one).
        if on, !((webView as? WebKitWebView)?.hadRecentUserInput() ?? false) {
            webView.evaluateJavaScript(PaneFullscreenScript.exitScript, completionHandler: nil)
            return
        }
        apply(.contentFullscreenChanged(on))
    }
}
