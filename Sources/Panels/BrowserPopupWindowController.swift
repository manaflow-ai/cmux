import AppKit
import Bonsplit
import ObjectiveC
import WebKit

func browserPopupContentRect(
    requestedWidth: CGFloat?,
    requestedHeight: CGFloat?,
    requestedX: CGFloat?,
    requestedTopY: CGFloat?,
    visibleFrame: NSRect,
    defaultWidth: CGFloat = 800,
    defaultHeight: CGFloat = 600,
    minWidth: CGFloat = 200,
    minHeight: CGFloat = 150
) -> NSRect {
    let clampedWidth = min(max(requestedWidth ?? defaultWidth, minWidth), visibleFrame.width)
    let clampedHeight = min(max(requestedHeight ?? defaultHeight, minHeight), visibleFrame.height)

    let x: CGFloat
    let y: CGFloat
    if let requestedX, let requestedTopY {
        x = max(visibleFrame.minX, min(requestedX, visibleFrame.maxX - clampedWidth))

        // Web content expresses popup Y as distance from the screen's top edge,
        // while AppKit window origins are bottom-up.
        let appKitY = visibleFrame.maxY - requestedTopY - clampedHeight
        y = max(visibleFrame.minY, min(appKitY, visibleFrame.maxY - clampedHeight))
    } else {
        x = visibleFrame.midX - clampedWidth / 2
        y = visibleFrame.midY - clampedHeight / 2
    }

    return NSRect(x: x, y: y, width: clampedWidth, height: clampedHeight)
}

/// Hosts a popup `CmuxWebView` in a standalone `NSPanel`, created when a page
/// calls `window.open()` (scripted new-window requests).
///
/// Lifecycle:
/// - The controller self-retains via `objc_setAssociatedObject` on its panel.
/// - Released in `windowWillClose(_:)` when the panel closes.
/// - The opener `BrowserPanel` also keeps a strong reference for deterministic
///   cleanup when the opener tab or workspace is closed.
/// NSPanel subclass that intercepts Cmd+W before the swizzled
/// `cmux_performKeyEquivalent` can dispatch it to the main menu's
/// "Close Tab" action (which would close the parent browser tab).
private class BrowserPopupPanel: NSPanel {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Cmd+W: close this popup panel only
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command,
           event.charactersIgnoringModifiers == "w" {
            #if DEBUG
            dlog("popup.panel.cmdW close")
            #endif
            performClose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor
final class BrowserPopupWindowController: NSObject, NSWindowDelegate {

    static let maxNestingDepth = 3

    let webView: CmuxWebView
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

    private static var associatedObjectKey: UInt8 = 0

    init(
        configuration: WKWebViewConfiguration,
        windowFeatures: WKWindowFeatures,
        openerPanel: BrowserPanel?,
        parentPopupController: BrowserPopupWindowController? = nil,
        nestingDepth: Int = 0
    ) {
        self.openerPanel = openerPanel
        self.parentPopupController = parentPopupController
        self.nestingDepth = nestingDepth

        let browserContextSource = parentPopupController?.webView.configuration ?? openerPanel?.webView.configuration
        if let browserContextSource {
            BrowserPanel.configureWebViewConfiguration(
                configuration,
                websiteDataStore: browserContextSource.websiteDataStore,
                processPool: browserContextSource.processPool
            )
        }

        // Create popup web view with WebKit's supplied configuration after
        // overlaying the opener's browser context so OAuth popups keep cmux's
        // shared cookie/storage scope and opener linkage.
        let webView = CmuxWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
        if #available(macOS 13.3, *) {
            webView.isInspectable = true
        }
        webView.underPageBackgroundColor = GhosttyBackgroundTheme.currentColor()
        webView.customUserAgent = BrowserUserAgentSettings.safariUserAgent
        self.webView = webView

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
        let contentRect = browserPopupContentRect(
            requestedWidth: w,
            requestedHeight: h,
            requestedX: windowFeatures.x.map { CGFloat($0.doubleValue) },
            requestedTopY: windowFeatures.y.map { CGFloat($0.doubleValue) },
            visibleFrame: visibleFrame,
            defaultWidth: defaultWidth,
            defaultHeight: defaultHeight,
            minWidth: minWidth,
            minHeight: minHeight
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
        dlog("popup.init depth=\(nestingDepth) size=\(Int(contentRect.width))x\(Int(contentRect.height)) opener=\(openerPanel?.id.uuidString.prefix(5) ?? "nil")")
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

    // MARK: - Popup lifecycle

    func closePopup() {
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

    func windowWillClose(_ notification: Notification) {
        #if DEBUG
        dlog("popup.close depth=\(nestingDepth)")
        #endif

        closeAllChildPopups()

        // Invalidate observations
        titleObservation?.invalidate()
        titleObservation = nil
        urlObservation?.invalidate()
        urlObservation = nil

        // Tear down web view
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
            dlog("popup.nested.blocked depth=\(nextDepth) max=\(Self.maxNestingDepth)")
            #endif
            return nil
        }
        let child = BrowserPopupWindowController(
            configuration: configuration,
            windowFeatures: windowFeatures,
            openerPanel: openerPanel,
            parentPopupController: self,
            nestingDepth: nextDepth
        )
        addChildPopup(child)
        return child.webView
    }

    func openInOpenerTab(_ url: URL) {
        if let openerPanel {
            openerPanel.openLinkInNewTab(url: url)
        } else {
            NSWorkspace.shared.open(url)
        }
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
        dlog("popup.webViewDidClose")
        #endif
        controller?.closePopup()
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        // External URL check
        if let url = navigationAction.request.url,
           browserShouldOpenURLExternally(url) {
            NSWorkspace.shared.open(url)
            return nil
        }

        let isScriptedPopup = browserNavigationShouldCreatePopup(
            navigationType: navigationAction.navigationType,
            modifierFlags: navigationAction.modifierFlags,
            buttonNumber: navigationAction.buttonNumber,
            hasRecentMiddleClickIntent: CmuxWebView.hasRecentMiddleClickIntent(for: webView)
        )

        if isScriptedPopup {
            return controller?.createNestedPopup(
                configuration: configuration,
                windowFeatures: windowFeatures
            )
        }

        if let url = navigationAction.request.url {
            controller?.openInOpenerTab(url)
        }
        return nil
    }

    // MARK: - JS Dialogs (parity with main browser)

    private func javaScriptDialogTitle(for webView: WKWebView) -> String {
        if let absolute = webView.url?.absoluteString, !absolute.isEmpty {
            return String(localized: "browser.dialog.pageSaysAt", defaultValue: "The page at \(absolute) says:")
        }
        return String(localized: "browser.dialog.pageSays", defaultValue: "This page says:")
    }

    private func presentDialog(
        _ alert: NSAlert,
        for webView: WKWebView,
        completion: @escaping (NSApplication.ModalResponse) -> Void
    ) {
        if let window = webView.window {
            alert.beginSheetModal(for: window, completionHandler: completion)
            return
        }
        completion(alert.runModal())
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping () -> Void
    ) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = javaScriptDialogTitle(for: webView)
        alert.informativeText = message
        alert.addButton(withTitle: String(localized: "common.ok", defaultValue: "OK"))
        presentDialog(alert, for: webView) { _ in completionHandler() }
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (Bool) -> Void
    ) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = javaScriptDialogTitle(for: webView)
        alert.informativeText = message
        alert.addButton(withTitle: String(localized: "common.ok", defaultValue: "OK"))
        alert.addButton(withTitle: String(localized: "common.cancel", defaultValue: "Cancel"))
        presentDialog(alert, for: webView) { response in
            completionHandler(response == .alertFirstButtonReturn)
        }
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (String?) -> Void
    ) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = javaScriptDialogTitle(for: webView)
        alert.informativeText = prompt
        alert.addButton(withTitle: String(localized: "common.ok", defaultValue: "OK"))
        alert.addButton(withTitle: String(localized: "common.cancel", defaultValue: "Cancel"))

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.stringValue = defaultText ?? ""
        alert.accessoryView = field

        presentDialog(alert, for: webView) { response in
            if response == .alertFirstButtonReturn {
                completionHandler(field.stringValue)
            } else {
                completionHandler(nil)
            }
        }
    }

    func webView(
        _ webView: WKWebView,
        runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping ([URL]?) -> Void
    ) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        panel.begin { result in
            completionHandler(result == .OK ? panel.urls : nil)
        }
    }

    func webView(
        _ webView: WKWebView,
        requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType,
        decisionHandler: @escaping (WKPermissionDecision) -> Void
    ) {
        decisionHandler(.prompt)
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
        // Only guard main-frame navigations
        guard navigationAction.targetFrame?.isMainFrame != false else {
            decisionHandler(.allow)
            return
        }

        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }

        // External URL schemes → hand off to macOS
        if browserShouldOpenURLExternally(url) {
            NSWorkspace.shared.open(url)
            #if DEBUG
            dlog("popup.nav.external url=\(url.absoluteString)")
            #endif
            decisionHandler(.cancel)
            return
        }

        // Insecure HTTP → show same prompt as main browser
        if browserShouldBlockInsecureHTTPURL(url) {
            #if DEBUG
            dlog("popup.nav.insecureHTTP url=\(url.absoluteString)")
            #endif
            controller?.presentInsecureHTTPAlert(for: url, in: webView, decisionHandler: decisionHandler)
            return
        }

        decisionHandler(.allow)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        if !navigationResponse.isForMainFrame {
            decisionHandler(.allow)
            return
        }

        if let scheme = navigationResponse.response.url?.scheme?.lowercased(),
           scheme != "http", scheme != "https" {
            decisionHandler(.allow)
            return
        }

        if let response = navigationResponse.response as? HTTPURLResponse {
            let contentDisposition = response.value(forHTTPHeaderField: "Content-Disposition") ?? ""
            if contentDisposition.lowercased().hasPrefix("attachment") {
                decisionHandler(.download)
                return
            }
        }

        if !navigationResponse.canShowMIMEType {
            decisionHandler(.download)
            return
        }

        decisionHandler(.allow)
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

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        #if DEBUG
        dlog("popup.download.didBecome source=navigationAction")
        #endif
        download.delegate = downloadDelegate
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        #if DEBUG
        dlog("popup.download.didBecome source=navigationResponse")
        #endif
        download.delegate = downloadDelegate
    }
}
