import AppKit
public import Foundation
public import WebKit
import CmuxNextCompat
import CmuxNextDesign

// MARK: - Navigation

extension WebKitTab: WKNavigationDelegate {
    public func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        preferences: WKWebpagePreferences,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy, WKWebpagePreferences) -> Void
    ) {
        if navigationAction.shouldPerformDownload {
            return admitDownload(navigationAction.request.url) { decisionHandler($0 ? .download : .cancel, preferences) }
        }
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow, preferences)
            return
        }

        let isUserLinkClick = navigationAction.navigationType == .linkActivated
        if isUserLinkClick, Self.isWebScheme(url) {
            switch LinkClick(navigationAction, in: self) {
            case .pageDefault, .navigate: break
            case .open(let disposition):
                decisionHandler(.cancel, preferences)
                emit(.openURL(url, disposition))
                return
            case .download:
                return admitDownload(navigationAction.request.url) { decisionHandler($0 ? .download : .cancel, preferences) }
            }
        }

        if !Self.isWebScheme(url) {
            decisionHandler(.cancel, preferences)
            // Other apps open only from a click in the main frame, never from
            // a script or a redirect.
            if isUserLinkClick, navigationAction.targetFrame?.isMainFrame ?? true {
                BrowserExternalApps.shared.open(url, from: navigationAction.sourcePage, ask: enqueuePrompt)
            }
            return
        }
        // A local Markdown file shows in cmux's markdown page, not as text (LocalFileHandoff).
        if navigationAction.targetFrame?.isMainFrame ?? true, url.isHandedOff(by: .webkit) { emit(.openLocalFile(url)); return decisionHandler(.cancel, preferences) }
        if cancelsFormResubmission(navigationAction, decisionHandler: { decisionHandler(.cancel, preferences) }) { return }
        // The organization's URLBlocklist (Chrome policy) holds for every frame; a main frame shows why.
        if let engine, engine.urlFilter.blocks(url) {
            decisionHandler(.cancel, preferences)
            if navigationAction.targetFrame?.isMainFrame ?? true { engine.showBlockedByOrganization(url, in: self) }
            return
        }
        applySiteSettings(to: preferences, for: navigationAction)
        // This view's own main-frame navigation, from here on not cancelled by this method: the
        // newest one decides, as WebKit lets only the newest go ahead. A new window's action has
        // no target frame and leaves it as it was.
        if navigationAction.targetFrame?.isMainFrame == true {
            let get = (navigationAction.request.httpMethod?.uppercased() ?? "GET") == "GET"
            mainFramePlayableVideo = get && navigationAction.navigationType != .backForward && RemoteVideoPage.plays(url) ? url : nil
        }
        guard navigationAction.targetFrame?.isMainFrame ?? true, let engine else { return decisionHandler(.allow, preferences) }
        navigationSourceSite = pageSite
        engine.admitMainFrameLoad(url, in: self) { decisionHandler($0 ? .allow : .cancel, preferences) }
    }

    public func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void
    ) {
        mainFrameStatuses.record(navigationResponse)
        let isAttachment = (navigationResponse.response as? HTTPURLResponse)
            .flatMap { $0.value(forHTTPHeaderField: "Content-Disposition") }?
            .lowercased()
            .hasPrefix("attachment") ?? false
        if navigationResponse.isForMainFrame, !isAttachment, !navigationResponse.canShowMIMEType,
           let url = navigationResponse.response.url, url == mainFramePlayableVideo {
            // A video sent as a generic file plays in the tab, at its own address. A simulated
            // load, not `loadHTMLString`: the player takes the video's place in the back list.
            decisionHandler(.cancel)
            webView.loadSimulatedRequest(URLRequest(url: url), responseHTML: RemoteVideoPage.html(for: url))
        } else if navigationResponse.isForMainFrame, isAttachment || !navigationResponse.canShowMIMEType {
            // The page that started the navigation counts the download.
            admitDownload(navigationResponse.response.url, site: navigationSourceSite) { decisionHandler($0 ? .download : .cancel) }
        } else {
            decisionHandler(.allow)
        }
    }

    public func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        downloads.register(download, source: navigationAction.request.url)
    }

    public func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        downloads.register(download, source: navigationResponse.response.url)
    }

    public func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation?) {
        guard let id = navigationID(for: navigation, creating: true) else { return }
        apply(.started(id, url: webView.url))
    }

    public func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation?) {
        guard let id = navigationID(for: navigation, creating: false) else { return }
        apply(.redirected(id, url: webView.url))
    }

    public func webView(_ webView: WKWebView, didCommit navigation: WKNavigation?) {
        restored.navigationCommitted(url: webView.url)
        formResubmissionCommitted()
        pageDidCommit()
        guard let id = navigationID(for: navigation, creating: false) else { return }
        apply(.committed(id, url: webView.url))
        pageInfoActivity.documentCommitted(origin: webView.url.flatMap(PageInfoSite.origin(of:)))
        // The title can arrive before the commit (back/forward cache), and
        // the commit clears it, so read the authoritative value again.
        apply(.titleChanged(webView.title))
        syncHistory()
        syncSecurity()
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
        restored.documentLoaded()
        guard let id = navigationID(for: navigation, creating: false) else { return }
        forgetNavigation(navigation)
        apply(.finished(id))
        pageDidFinish()
        // The load ended: a document with no contentful paint (an empty body) shows as it is.
        removeStandIn()
        syncHistory()
        refreshFavicon()
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation?, withError error: any Error) {
        let failure = BrowserLoadError(error)
        // The committed document stopped loading: it keeps the page area, so
        // WebKit draws its background again (`pageDidCommit`). A cancellation
        // is a newer navigation taking this one's place, and that one's commit
        // decides: handing the page area back here would draw white over a
        // document that has not painted yet. `stop()` settles its own case.
        if !failure.isBenignInterruption { pageDidFinish(); removeStandIn() }
        guard let id = navigationID(for: navigation, creating: false) else { return }
        forgetNavigation(navigation)
        apply(.failed(id, failure))
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation?, withError error: any Error) {
        restored.navigationCommitted(url: nil)  // a saved entry that failed to load is no longer loading
        formResubmissionFailed()
        let failure = BrowserLoadError(error)
        // Nothing is going to commit, so whatever is on screen keeps the page
        // area; without this a document that committed but never finished
        // keeps no background for good (`WebKitTab+LoadingBackground`). A
        // benign interruption is a newer navigation taking this one's place,
        // and that one's commit decides, as in `didFail`.
        if !failure.isBenignInterruption { pageDidFinish(); removeStandIn() }
        guard let id = navigationID(for: navigation, creating: false) else { return }
        forgetNavigation(navigation)
        apply(.failed(id, failure))
    }

    /// WebKit gives no reason; the sad tab says the page crashed.
    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // No commit or finish is coming, so the page area goes back to
        // WebKit's own background rather than keeping none for good.
        // Unconditionally, not through `pageDidFinish`: a crash can leave
        // `webView.url` nil, which that one reads as a blank page and skips,
        // putting the tab back in the stuck state this is here to prevent.
        pageBaseHold.cancel()
        setDrawsPageBackground(true)
        removeStandIn()
        apply(.processExited(BrowserProcessExit(reason: .crashed)))
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
        // The modified click's mapping (the link menu's rows open by URL).
        let click = LinkClick(navigationAction, in: self)
        guard hasDelegate, !click.runsInOpener(navigationAction.request, tab: self),
              let child = makeChildTab(configuration: configuration) else { return nil }
        if case .open(let explicit) = click {
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
        decidePermission(kind, origin: Self.displayOrigin(origin)) { decisionHandler($0 ? .grant : .deny) }
    }

    // Location, notifications and the page's window.print() have only private
    // WKUIDelegate methods (WKUIDelegatePrivate); without them WebKit refuses
    // the first two unasked and prints nothing.
    @objc(_webView:requestGeolocationPermissionForOrigin:initiatedByFrame:decisionHandler:)
    func requestLocation(_ webView: WKWebView, origin: WKSecurityOrigin, frame: WKFrameInfo,
                         decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void) {
        decidePermission(.location, origin: Self.displayOrigin(origin)) { decisionHandler($0 ? .grant : .deny) }
    }

    @objc(_webView:requestNotificationPermissionForSecurityOrigin:decisionHandler:)
    func requestNotifications(_ webView: WKWebView, origin: WKSecurityOrigin, decisionHandler: @escaping @MainActor (Bool) -> Void) {
        decidePermission(.notifications, origin: Self.displayOrigin(origin), granted: decisionHandler)
    }

    @objc(_webView:printFrame:pdfFirstPageSize:completionHandler:)
    func printFrame(_ webView: WKWebView, frame: AnyObject?, pdfFirstPageSize: CGSize, completionHandler: @escaping @MainActor () -> Void) {
        _ = BrowserPagePrint(self).printWebKit(webView, done: completionHandler) // the page waits for the panel
    }

    public func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor () -> Void
    ) {
        enqueuePrompt(.alert(message: message), origin: Self.displayOrigin(frame.securityOrigin)) { _ in completionHandler() }
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
        // Files an agent offered (`browser.page.upload`) answer first; `[]` (a chooser they cannot fill) cancels.
        if let offered = agentFiles.answer(multiple: parameters.allowsMultipleSelection,
                                           folder: parameters.allowsDirectories, save: false) {
            completionHandler(offered.isEmpty ? nil : offered)
            return
        }
        // The one file-input path (WebFileInputAnswering) every WebKit view shares: in the app the made-ahead panel.
        // A tab whose engine is gone ends the input as a cancel.
        guard let engine else {
            completionHandler(nil)
            return
        }
        engine.fileInput.answerFileInput(allowsMultipleSelection: parameters.allowsMultipleSelection,
                                         allowsDirectories: parameters.allowsDirectories,
                                         window: webView.window, completion: completionHandler)
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
        if message.name == WebKitContextHit.handlerName {
            contextHit = BrowserContextMenuTarget.webKitHit(message.body).map { (target: $0, at: ContinuousClock.now) }
            return
        }
        guard message.name == PaneFullscreenScript.messageHandlerName,
              message.frameInfo.isMainFrame,
              let on = message.body as? Bool else { return }
        // Entering hides the chrome: only in answer to the user (a script
        // could otherwise hide the address bar and draw a fake one).
        if on, !((webView as? WebKitWebView)?.hadRecentUserInput() ?? false) {
            WebKitGestureFreeEvaluation(webView: webView).run(PaneFullscreenScript.exitScript, in: .page)
            return
        }
        apply(.contentFullscreenChanged(on))
    }
}
