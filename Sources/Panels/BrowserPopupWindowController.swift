import AppKit
import Bonsplit
import CmuxBrowser
import CmuxSettings
import ObjectiveC
import WebKit

/// NSPanel subclass that intercepts the configured Close Tab shortcut before the swizzled
/// `cmux_performKeyEquivalent` can dispatch it to the main menu's
/// "Close Tab" action (which would close the parent browser tab).
final class BrowserPopupPanel: NSPanel {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if AppDelegate.shared?.handleBrowserPopupCloseShortcutKeyEquivalent(event: event, popupWindow: self) == true {
            return true
        }
        if KeyboardShortcutSettings.Action.closeTab.shouldSuppressStaleDefaultShortcut(matching: event) {
            #if DEBUG
            cmuxDebugLog("popup.panel.closeShortcut suppressStaleDefault")
            #endif
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// Hosts a popup `CmuxWebView` in a standalone `NSPanel`, created when a page
/// calls `window.open()` (scripted new-window requests).
///
/// Lifecycle:
/// - The controller self-retains via `objc_setAssociatedObject` on its panel.
/// - Released in `windowWillClose(_:)` when the panel closes.
/// - The opener `BrowserPanel` also keeps a strong reference for deterministic
///   cleanup when the opener tab or workspace is closed.
@MainActor
final class BrowserPopupWindowController: NSObject, NSWindowDelegate {

    static let maxNestingDepth = 3

    let webView: CmuxWebView
    private let browserContext: BrowserPopupBrowserContext
    private let panel: NSPanel
    private let urlLabel: NSTextField
    private weak var openerPanel: BrowserPanel?
    private weak var parentPopupController: BrowserPopupWindowController?
    private let nestingDepth: Int
    private var titleObservation: NSKeyValueObservation?
    private var urlObservation: NSKeyValueObservation?
    private var childPopups: [BrowserPopupWindowController] = []
    private let popupUIDelegate: PopupUIDelegate
    private let popupNavigationDelegate: PopupNavigationDelegate
    private let downloadDelegate: BrowserDownloadDelegate
    private let webAuthnCoordinator: BrowserWebAuthnCoordinator

    private static var associatedObjectKey: UInt8 = 0

    init(
        configuration: WKWebViewConfiguration,
        windowFeatures: WKWindowFeatures,
        browserContext: BrowserPopupBrowserContext,
        openerPanel: BrowserPanel?,
        parentPopupController: BrowserPopupWindowController? = nil,
        nestingDepth: Int = 0
    ) {
        self.browserContext = browserContext
        self.openerPanel = openerPanel
        self.parentPopupController = parentPopupController
        self.nestingDepth = nestingDepth

        BrowserPanel.configureWebViewConfiguration(
            configuration,
            websiteDataStore: browserContext.websiteDataStore
        )

        // Create popup web view with WebKit's supplied configuration after
        // overlaying the opener's browser context so OAuth popups keep cmux's
        // shared cookie/storage scope and opener linkage.
        let webView = CmuxWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
        if #available(macOS 13.3, *) {
            webView.isInspectable = true
        }
        webView.underPageBackgroundColor = GhosttyBackgroundTheme.currentColor()
        webView.customUserAgent = String.safariDesktopUserAgent
        BrowserThemeSettings.apply(openerPanel?.currentBrowserThemeMode ?? BrowserThemeSettings.mode(), to: webView)
        self.webView = webView
        self.webAuthnCoordinator = BrowserWebAuthnCoordinator()

        // --- Window sizing from WKWindowFeatures ---
        let defaultWidth: CGFloat = 800
        let defaultHeight: CGFloat = 600
        let minWidth: CGFloat = 200
        let minHeight: CGFloat = 150

        let w = max(windowFeatures.width?.doubleValue ?? defaultWidth, minWidth)
        let h = max(windowFeatures.height?.doubleValue ?? defaultHeight, minHeight)

        // Screen-clamping: use opener's screen or main screen
        let screen = openerPanel?.webView.window?.screen ?? NSScreen.main ?? NSScreen.screens.first
        let visibleFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let contentRect = BrowserPopupContentGeometry(
            defaultWidth: defaultWidth,
            defaultHeight: defaultHeight,
            minWidth: minWidth,
            minHeight: minHeight
        ).contentRect(
            requestedWidth: w,
            requestedHeight: h,
            requestedX: windowFeatures.x.map { CGFloat($0.doubleValue) },
            requestedTopY: windowFeatures.y.map { CGFloat($0.doubleValue) },
            visibleFrame: visibleFrame
        )

        // Style mask: titled + closable + resizable by default.
        // allowsResizing is a separate property from chrome-visibility flags
        // (toolbarsVisibility, menuBarVisibility, statusBarVisibility).
        var styleMask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable]
        if windowFeatures.allowsResizing?.boolValue != false {
            styleMask.insert(.resizable)
        }

        let panel = BrowserPopupPanel(
            contentRect: contentRect,
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )
        panel.identifier = NSUserInterfaceItemIdentifier("cmux.browser-popup")
        panel.level = NSWindow.Level.normal
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: minWidth, height: minHeight)
        panel.title = String(localized: "browser.popup.loadingTitle", defaultValue: "Loading\u{2026}")
        self.panel = panel

        let urlLabel = NSTextField(labelWithString: "")
        self.urlLabel = urlLabel

        // Build delegate objects before super.init so they can be assigned
        let uiDel = PopupUIDelegate()
        let navDel = PopupNavigationDelegate()
        let dlDel = BrowserDownloadDelegate()
        self.popupUIDelegate = uiDel
        self.popupNavigationDelegate = navDel
        self.downloadDelegate = dlDel

        super.init()

        // --- URL label for phishing protection ---
        urlLabel.translatesAutoresizingMaskIntoConstraints = false
        urlLabel.font = .systemFont(ofSize: 11)
        urlLabel.textColor = .secondaryLabelColor
        urlLabel.lineBreakMode = .byTruncatingMiddle
        urlLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let containerView = NSView()
        containerView.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(urlLabel)
        containerView.addSubview(webView)
        webView.translatesAutoresizingMaskIntoConstraints = false

        panel.contentView = containerView
        NSLayoutConstraint.activate([
            urlLabel.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 4),
            urlLabel.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 8),
            urlLabel.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -8),
            urlLabel.heightAnchor.constraint(equalToConstant: 16),

            webView.topAnchor.constraint(equalTo: urlLabel.bottomAnchor, constant: 2),
            webView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
        ])

        // --- Delegates ---
        uiDel.controller = self
        navDel.controller = self
        navDel.downloadDelegate = dlDel
        webView.uiDelegate = uiDel
        webView.navigationDelegate = navDel
        webAuthnCoordinator.install(on: webView)

        // Context menu "Open Link in New Tab" → open in opener's workspace,
        // not as a nested popup. Falls back to system browser if opener is gone.
        webView.onContextMenuOpenLinkInNewTab = { [weak self] url in
            if let opener = self?.openerPanel {
                opener.openLinkInNewTab(url: url)
            } else {
                NSWorkspace.shared.open(url)
            }
        }

        // --- KVO for title and URL ---
        titleObservation = webView.observe(\.title, options: [.new]) { [weak self] _, change in
            guard let newTitle = change.newValue ?? nil, !newTitle.isEmpty else { return }
            Task { @MainActor [weak self] in
                self?.panel.title = newTitle
            }
        }
        urlObservation = webView.observe(\.url, options: [.new]) { [weak self] _, change in
            let displayURL = change.newValue??.absoluteString ?? ""
            Task { @MainActor [weak self] in
                self?.urlLabel.stringValue = displayURL
            }
        }

        // --- Self-retention via associated object on panel ---
        objc_setAssociatedObject(panel, &Self.associatedObjectKey, self, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)

        panel.delegate = self

        #if DEBUG
        cmuxDebugLog("popup.init depth=\(nestingDepth) size=\(Int(contentRect.width))x\(Int(contentRect.height)) opener=\(openerPanel?.id.uuidString.prefix(5) ?? "nil")")
        #endif

        panel.makeKeyAndOrderFront(self)
    }

    // MARK: - Child popup tracking

    func addChildPopup(_ child: BrowserPopupWindowController) {
        childPopups.append(child)
    }

    func removeChildPopup(_ child: BrowserPopupWindowController) {
        childPopups.removeAll { $0 === child }
    }

    func setBrowserThemeMode(_ mode: BrowserThemeMode) {
        BrowserThemeSettings.apply(mode, to: webView)
        for child in childPopups {
            child.setBrowserThemeMode(mode)
        }
    }

    // MARK: - Popup lifecycle

    func closePopup() {
        WebViewInspectorTeardown.closeAllInspectors(in: panel)
        panel.close() // triggers windowWillClose
    }

    func closeAllChildPopups() {
        let children = childPopups
        childPopups.removeAll()
        for child in children {
            child.closeAllChildPopups()
            child.closePopup()
        }
    }

    // MARK: - NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        WebViewInspectorTeardown.closeAllInspectors(in: sender)
        return true
    }

    func windowWillClose(_ notification: Notification) {
        #if DEBUG
        cmuxDebugLog("popup.close depth=\(nestingDepth)")
        #endif

        WebViewInspectorTeardown.closeInspector(for: webView)
        closeAllChildPopups()

        // Invalidate observations
        titleObservation?.invalidate()
        titleObservation = nil
        urlObservation?.invalidate()
        urlObservation = nil

        // Tear down web view
        webAuthnCoordinator.uninstall(from: webView)
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil

        // Unregister from parent (opener panel or parent popup)
        openerPanel?.removePopupController(self)
        parentPopupController?.removeChildPopup(self)

        // Release self-retention
        objc_setAssociatedObject(panel, &Self.associatedObjectKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    // MARK: - Nested popup creation

    func createNestedPopup(
        configuration: WKWebViewConfiguration,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        let nextDepth = nestingDepth + 1
        if nextDepth > Self.maxNestingDepth {
            #if DEBUG
            cmuxDebugLog("popup.nested.blocked depth=\(nextDepth) max=\(Self.maxNestingDepth)")
            #endif
            return nil
        }
        let child = BrowserPopupWindowController(
            configuration: configuration,
            windowFeatures: windowFeatures,
            browserContext: browserContext,
            openerPanel: openerPanel,
            parentPopupController: self,
            nestingDepth: nextDepth
        )
        addChildPopup(child)
        return child.webView
    }

    func openInOpenerTab(_ request: URLRequest) {
        if let openerPanel {
            openerPanel.openLinkInNewTab(request: request)
        } else if let url = request.url {
            NSWorkspace.shared.open(url)
        }
    }

    fileprivate func handleWebContentProcessTermination(for terminatedWebView: WKWebView) {
        guard terminatedWebView === webView else { return }
#if DEBUG
        cmuxDebugLog("popup.webcontent.terminated depth=\(nestingDepth)")
#endif
        closePopup()
    }

    fileprivate func requestNavigation(_ request: URLRequest, in webView: WKWebView) {
        guard let url = request.url else { return }

        if BrowserInsecureHTTPSettings.shouldBlock(url) {
            presentInsecureHTTPAlert(for: url, in: webView) { [weak webView] policy in
                guard policy == .allow, let webView else { return }
                browserLoadRequest(request, in: webView)
            }
            return
        }

        browserLoadRequest(request, in: webView)
    }

    // MARK: - Insecure HTTP prompt (parity with main browser)

    /// Shows the same 3-button insecure HTTP alert as the main browser.
    /// Reuses the global helpers from BrowserPanel.swift.
    fileprivate func presentInsecureHTTPAlert(
        for url: URL,
        in webView: WKWebView,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let host = BrowserInsecureHTTPSettings.normalizeHost(url.host ?? "") else {
            decisionHandler(.cancel)
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "browser.error.insecure.title", defaultValue: "Connection isn\u{2019}t secure")
        alert.informativeText = String(localized: "browser.error.insecure.message", defaultValue: "\(host) uses plain HTTP, so traffic can be read or modified on the network.\n\nOpen this URL in your default browser, or proceed in cmux.")
        alert.addButton(withTitle: String(localized: "browser.openInDefaultBrowser", defaultValue: "Open in Default Browser"))
        alert.addButton(withTitle: String(localized: "browser.proceedInCmux", defaultValue: "Proceed in cmux"))
        alert.addButton(withTitle: String(localized: "common.cancel", defaultValue: "Cancel"))
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = String(localized: "browser.alwaysAllowHost", defaultValue: "Always allow this host in cmux")

        let handleResponse: (NSApplication.ModalResponse) -> Void = { [weak alert] response in
            if browserShouldPersistInsecureHTTPAllowlistSelection(
                response: response,
                suppressionEnabled: alert?.suppressionButton?.state == .on
            ) {
                BrowserInsecureHTTPSettings.addAllowedHost(host)
            }
            switch response {
            case .alertFirstButtonReturn:
                // Open in default browser, cancel popup navigation
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
            case .alertSecondButtonReturn:
                // Proceed in popup
                decisionHandler(.allow)
            default:
                decisionHandler(.cancel)
            }
        }

        if let window = webView.window {
            alert.beginSheetModal(for: window, completionHandler: handleResponse)
            return
        }
        handleResponse(alert.runModal())
    }
}

// MARK: - PopupUIDelegate

private class PopupUIDelegate: NSObject, WKUIDelegate {
    weak var controller: BrowserPopupWindowController?

    func webViewDidClose(_ webView: WKWebView) {
        #if DEBUG
        cmuxDebugLog("popup.webViewDidClose")
        #endif
        controller?.closePopup()
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let url = navigationAction.request.url,
           BrowserExternalNavigationAction.shouldRoute(url) {
            browserHandleExternalNavigation(
                url,
                source: "popupUIDelegate",
                webView: webView,
                loadFallbackRequest: { [weak controller] request in
                    controller?.requestNavigation(request, in: webView)
                }
            )
            return nil
        }

        let isScriptedPopup = BrowserUserGestureNavigation(
            navigationType: navigationAction.navigationType,
            modifierFlags: navigationAction.modifierFlags,
            buttonNumber: navigationAction.buttonNumber,
            hasRecentMiddleClickIntent: CmuxWebView.hasRecentMiddleClickIntent(for: webView),
            currentEventType: NSApp.currentEvent?.type,
            currentEventButtonNumber: NSApp.currentEvent?.buttonNumber
        ).createsPopup(
            popupFeaturesWereSpecified: BrowserPopupWindowFeatures(windowFeatures: windowFeatures).wereSpecified
        )

        if isScriptedPopup {
            return controller?.createNestedPopup(
                configuration: configuration,
                windowFeatures: windowFeatures
            )
        }

        if navigationAction.request.url != nil {
            controller?.openInOpenerTab(navigationAction.request)
        }
        return nil
    }

    // MARK: - JS Dialogs (parity with main browser)

    /// Localized page-says title for a dialog. `String(localized:)` stays app-side
    /// so it binds to the app bundle's `.xcstrings` (preserving translations); the
    /// resolved title is passed into the package presenter per call.
    private func javaScriptDialogTitle(for webView: WKWebView) -> String {
        if let absolute = webView.url?.absoluteString, !absolute.isEmpty {
            return String(localized: "browser.dialog.pageSaysAt", defaultValue: "The page at \(absolute) says:")
        }
        return String(localized: "browser.dialog.pageSays", defaultValue: "This page says:")
    }

    /// Presenter carrying the app-resolved OK / Cancel labels for the dialog family.
    private var dialogPresenter: BrowserJavaScriptDialogPresenter {
        BrowserJavaScriptDialogPresenter(
            okButtonTitle: String(localized: "common.ok", defaultValue: "OK"),
            cancelButtonTitle: String(localized: "common.cancel", defaultValue: "Cancel")
        )
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping () -> Void
    ) {
        dialogPresenter.runAlert(
            message: message,
            dialogTitle: javaScriptDialogTitle(for: webView),
            for: webView,
            completionHandler: completionHandler
        )
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (Bool) -> Void
    ) {
        dialogPresenter.runConfirm(
            message: message,
            dialogTitle: javaScriptDialogTitle(for: webView),
            for: webView,
            completionHandler: completionHandler
        )
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (String?) -> Void
    ) {
        dialogPresenter.runTextInput(
            prompt: prompt,
            defaultText: defaultText,
            dialogTitle: javaScriptDialogTitle(for: webView),
            for: webView,
            completionHandler: completionHandler
        )
    }

    func webView(
        _ webView: WKWebView,
        runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping ([URL]?) -> Void
    ) {
        dialogPresenter.runOpenPanel(parameters: parameters, completionHandler: completionHandler)
    }

    func webView(
        _ webView: WKWebView,
        requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType,
        decisionHandler: @escaping (WKPermissionDecision) -> Void
    ) {
        dialogPresenter.resolveMediaCapture(decisionHandler: decisionHandler)
    }
}

// MARK: - PopupNavigationDelegate

private class PopupNavigationDelegate: NSObject, WKNavigationDelegate {
    weak var controller: BrowserPopupWindowController?
    var downloadDelegate: WKDownloadDelegate?

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        // Branch classification lives in the package; the delegate executes the
        // resolved case (external routing, insecure-HTTP prompt, allow/download).
        switch PopupNavigationActionDecision.resolve(
            url: navigationAction.request.url,
            isMainFrame: navigationAction.targetFrame?.isMainFrame != false,
            shouldPerformDownload: navigationAction.shouldPerformDownload
        ) {
        case .allow:
            decisionHandler(.allow)

        case .routeExternally(let url):
            // External URL schemes → hand off to macOS
            browserHandleExternalNavigation(
                url,
                source: "popupNavDelegate",
                webView: webView,
                loadFallbackRequest: { [weak controller] request in
                    controller?.requestNavigation(request, in: webView)
                }
            )
            decisionHandler(.cancel)

        case .promptInsecureHTTP(let url):
            // Insecure HTTP → show same prompt as main browser
            #if DEBUG
            cmuxDebugLog("popup.nav.insecureHTTP url=\(url.absoluteString)")
            #endif
            controller?.presentInsecureHTTPAlert(for: url, in: webView, decisionHandler: decisionHandler)

        case .download:
            decisionHandler(.download)
        }
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        // Branch classification lives in the package; the delegate executes the
        // resolved case. The download determination stays app-side (it consults
        // the app's download-filename resolver) and is evaluated lazily so it runs
        // only after the main-frame and scheme guards pass, matching the original.
        switch PopupNavigationResponseDecision.resolve(
            isForMainFrame: navigationResponse.isForMainFrame,
            scheme: navigationResponse.response.url?.scheme,
            isDownload: {
                let contentDisposition = (navigationResponse.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition")
                return BrowserDownloadFilenameResolver().navigationResponseDownloadReason(
                    mimeType: navigationResponse.response.mimeType, canShowMIMEType: navigationResponse.canShowMIMEType, contentDisposition: contentDisposition
                ) != nil
            }
        ) {
        case .allow:
            decisionHandler(.allow)

        case .download:
            decisionHandler(.download)
        }
    }

    func webView(
        _ webView: WKWebView,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        // Parity with main browser: performDefaultHandling enables system keychain
        // lookups, MDM client certs, and SSO extensions (e.g. Microsoft Entra ID).
        completionHandler(.performDefaultHandling, nil)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        controller?.handleWebContentProcessTermination(for: webView)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        #if DEBUG
        cmuxDebugLog("popup.download.didBecome source=navigationAction")
        #endif
        download.delegate = downloadDelegate
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        #if DEBUG
        cmuxDebugLog("popup.download.didBecome source=navigationResponse")
        #endif
        download.delegate = downloadDelegate
    }
}
