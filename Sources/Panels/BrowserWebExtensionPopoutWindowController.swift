import AppKit
import Foundation
import ObjectiveC
import WebKit

/// Hosts a `windows.create({type: "popup"})` window opened by a web extension —
/// e.g. Bitwarden's passkey-confirmation, unlock, and 2FA popouts.
///
/// The controller is both the `WKWebExtensionWindow` and the owner of the native
/// `NSWindow` + extension-page `WKWebView`; its single tab uses a dedicated adapter.
@available(macOS 15.4, *)
@MainActor
final class BrowserWebExtensionPopoutWindowController: NSObject, WKWebExtensionWindow, NSWindowDelegate, WKNavigationDelegate {
    private static let defaultSize = CGSize(width: 400, height: 600)
    private static let fallbackVisibleFrame = CGRect(x: 0, y: 0, width: 1440, height: 900)
    private static let minimumDimension: CGFloat = 50
    private static var downloadDelegateAssociationKey: UInt8 = 0

    let window: NSWindow
    let webView: WKWebView
    private(set) lazy var tab = BrowserWebExtensionPopoutTab(controller: self)
    private weak var support: BrowserWebExtensionSupport?
    private(set) weak var extensionContext: WKWebExtensionContext?
    private let popoutUIDelegate: BrowserWebExtensionPopoutUIDelegate
    private let downloadDelegate: BrowserDownloadDelegate
    private let subframeDownloadIntents = BrowserSubframeDownloadIntentTracker()
    private var childPopupControllers: [UUID: BrowserPopupWindowController] = [:]

    init(
        configuration: WKWebExtension.WindowConfiguration,
        context: WKWebExtensionContext,
        support: BrowserWebExtensionSupport
    ) {
        self.support = support
        self.extensionContext = context
        popoutUIDelegate = BrowserWebExtensionPopoutUIDelegate()
        downloadDelegate = BrowserDownloadDelegate()

        let webViewConfiguration = context.webViewConfiguration ?? WKWebViewConfiguration()
        webView = WKWebView(frame: .zero, configuration: webViewConfiguration)
#if DEBUG
        webView.isInspectable = true
#endif

        let visibleFrame = NSScreen.main?.visibleFrame
            ?? NSScreen.screens.first?.visibleFrame
            ?? Self.fallbackVisibleFrame
        let frame = Self.resolvedContentFrame(
            requestedFrame: configuration.frame,
            visibleFrame: visibleFrame
        )
        window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        // Standalone closable window: the stable identifier opts it into the
        // shared close-shortcut routing (`NSWindow.cmuxShouldOwnCloseShortcut`).
        window.identifier = NSUserInterfaceItemIdentifier("cmux.webExtensionPopout")
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.contentView = webView

        super.init()
        popoutUIDelegate.closeAction = { [weak self] in
            self?.closeFromExtensionOrUser()
        }
        popoutUIDelegate.newWindowAction = { [weak self] request in
            self?.routeNewWindowRequest(request)
        }
        popoutUIDelegate.scriptedPopupAction = { [weak self] configuration, windowFeatures in
            self?.createScriptedPopup(
                configuration: configuration,
                windowFeatures: windowFeatures
            )
        }
        downloadDelegate.savePanelParentWindow = { [weak window] in window }
        window.delegate = self
        webView.uiDelegate = popoutUIDelegate
        webView.navigationDelegate = self
        window.title = context.webExtension.displayName ?? String(
            localized: "browser.webExtension.action.help",
            defaultValue: "Extension"
        )

        if let url = configuration.tabURLs.first,
           support.canOpenExtensionPopupURL(url, for: context) {
            webView.load(URLRequest(url: url))
        }
        if configuration.shouldBeFocused {
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
        } else {
            window.orderFront(nil)
        }
    }

    static func resolvedContentFrame(
        requestedFrame: CGRect,
        visibleFrame proposedVisibleFrame: CGRect
    ) -> CGRect {
        let visibleFrame: CGRect
        if proposedVisibleFrame.origin.x.isFinite,
           proposedVisibleFrame.origin.y.isFinite,
           proposedVisibleFrame.width.isFinite,
           proposedVisibleFrame.height.isFinite,
           proposedVisibleFrame.width > 0,
           proposedVisibleFrame.height > 0 {
            visibleFrame = proposedVisibleFrame
        } else {
            visibleFrame = fallbackVisibleFrame
        }

        let maximumWidth = visibleFrame.width
        let maximumHeight = visibleFrame.height
        let minimumWidth = min(minimumDimension, maximumWidth)
        let minimumHeight = min(minimumDimension, maximumHeight)
        let defaultWidth = min(defaultSize.width, maximumWidth)
        let defaultHeight = min(defaultSize.height, maximumHeight)
        let width = requestedFrame.width.isFinite && requestedFrame.width >= minimumDimension
            ? min(requestedFrame.width, maximumWidth)
            : max(defaultWidth, minimumWidth)
        let height = requestedFrame.height.isFinite && requestedFrame.height >= minimumDimension
            ? min(requestedFrame.height, maximumHeight)
            : max(defaultHeight, minimumHeight)
        let centeredX = visibleFrame.midX - (width / 2)
        let centeredY = visibleFrame.midY - (height / 2)
        let requestedX = requestedFrame.origin.x.isFinite ? requestedFrame.origin.x : centeredX
        let requestedY = requestedFrame.origin.y.isFinite ? requestedFrame.origin.y : centeredY
        let x = min(max(requestedX, visibleFrame.minX), visibleFrame.maxX - width)
        let y = min(max(requestedY, visibleFrame.minY), visibleFrame.maxY - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    static func supportsInitialTabs(urlCount: Int, existingTabCount: Int) -> Bool {
        urlCount == 1 && existingTabCount == 0
    }

    var isKeyWindow: Bool {
        window.isKeyWindow
    }

    func owns(_ context: WKWebExtensionContext) -> Bool {
        extensionContext === context
    }

    func closeFromExtensionOrUser() {
        guard window.delegate === self else { return }
        window.delegate = nil
        webView.uiDelegate = nil
        closeChildPopups()
        support?.popoutDidClose(self)
        window.close()
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        window.delegate = nil
        webView.uiDelegate = nil
        closeChildPopups()
        support?.popoutDidClose(self)
    }

    // MARK: - WKWebExtensionWindow

    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] {
        owns(context) ? [tab] : []
    }

    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? {
        owns(context) ? tab : nil
    }

    func windowType(for context: WKWebExtensionContext) -> WKWebExtension.WindowType {
        .popup
    }

    func windowState(for context: WKWebExtensionContext) -> WKWebExtension.WindowState {
        .normal
    }

    func isPrivate(for context: WKWebExtensionContext) -> Bool {
        false
    }

    func frame(for context: WKWebExtensionContext) -> CGRect {
        owns(context) ? window.frame : .null
    }

    func screenFrame(for context: WKWebExtensionContext) -> CGRect {
        guard owns(context) else { return .null }
        return window.screen?.frame ?? NSScreen.main?.frame ?? .null
    }

    func focus(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        guard owns(context) else {
            completionHandler(NSError(domain: "cmux.webExtension.popup", code: 2))
            return
        }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        completionHandler(nil)
    }

    func close(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        guard owns(context) else {
            completionHandler(NSError(domain: "cmux.webExtension.popup", code: 2))
            return
        }
        closeFromExtensionOrUser()
        completionHandler(nil)
    }

    func canLoadExtensionRequestedURL(_ url: URL) -> Bool {
        guard let extensionContext else { return false }
        return support?.canOpenExtensionPopupURL(url, for: extensionContext) == true
    }

    static func canFallbackToExternalBrowser(for request: URLRequest) -> Bool {
        let method = request.httpMethod?.uppercased() ?? "GET"
        return method == "GET" && request.httpBody == nil && request.httpBodyStream == nil &&
            (request.allHTTPHeaderFields?.isEmpty ?? true)
    }

    private func routeNewWindowRequest(_ request: URLRequest) {
        guard let url = request.url else { return }
        if canLoadExtensionRequestedURL(url) {
            webView.load(request)
            return
        }
        _ = routeHTTPBrowserRequest(request)
    }

    private func createScriptedPopup(
        configuration: WKWebViewConfiguration,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        let popupID = UUID()
        let controller = BrowserPopupWindowController(
            configuration: configuration,
            windowFeatures: windowFeatures,
            browserContext: BrowserPopupBrowserContext(
                websiteDataStore: configuration.websiteDataStore
            ),
            openerPanel: nil,
            onClose: { [weak self] in
                self?.childPopupControllers.removeValue(forKey: popupID)
            }
        )
        childPopupControllers[popupID] = controller
        return controller.webView
    }

    private func closeChildPopups() {
        let controllers = Array(childPopupControllers.values)
        childPopupControllers.removeAll()
        for controller in controllers {
            controller.closeAllChildPopups()
            controller.closePopup()
        }
    }

    private func routeHTTPBrowserRequest(_ request: URLRequest) -> Bool {
        guard let url = request.url,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return false }
        if support?.openBrowserTab(
            url: nil,
            initialRequest: request,
            shouldActivate: true,
            webViewConfiguration: nil
        ) != nil {
            return true
        }
        if Self.canFallbackToExternalBrowser(for: request), NSWorkspace.shared.open(url) {
            return true
        }
        sentryCaptureWarning(
            "browser.webExtension.popup.externalNavigationFailed",
            category: "browser.webExtension",
            data: ["scheme": scheme, "host": url.host ?? ""]
        )
        return true
    }

    // MARK: - WKNavigationDelegate

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }
        let isForMainFrame = navigationAction.targetFrame?.isMainFrame != false
        let hasUserActivation = browserNavigationHasSimpleUserActivation()
        if !isForMainFrame, hasUserActivation {
            subframeDownloadIntents.record(url)
        }
        subframeDownloadIntents.updateIfNeeded(
            navigationAction,
            hasUserActivation: hasUserActivation
        )
        if navigationAction.shouldPerformDownload {
            let hasRecordedIntent = !isForMainFrame && subframeDownloadIntents.consume(for: url)
            decisionHandler(Self.actionDownloadPolicy(
                for: url,
                isForMainFrame: isForMainFrame,
                hasUserActivation: hasUserActivation,
                hasRecordedIntent: hasRecordedIntent,
                blocksInsecureHTTP: browserShouldBlockInsecureHTTPURL(url)
            ))
            return
        }
        if !isForMainFrame {
            decisionHandler(.allow)
            return
        }

        if navigationAction.targetFrame != nil, canLoadExtensionRequestedURL(url) {
            decisionHandler(.allow)
            return
        }

        if routeHTTPBrowserRequest(navigationAction.request) {
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.cancel)
    }

    static func actionDownloadPolicy(
        for url: URL,
        isForMainFrame: Bool,
        hasUserActivation: Bool,
        hasRecordedIntent: Bool,
        blocksInsecureHTTP: Bool
    ) -> WKNavigationActionPolicy {
        guard !url.browserShouldRouteExternalNavigation,
              !blocksInsecureHTTP,
              isForMainFrame || hasUserActivation || hasRecordedIntent else {
            return .cancel
        }
        return .download
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse
    ) async -> WKNavigationResponsePolicy {
        let responseURL = navigationResponse.response.url
        let allowsSubframeDownload = navigationResponse.isForMainFrame
            || subframeDownloadIntents.consume(for: responseURL)
        return Self.responsePolicy(
            for: navigationResponse.response,
            canShowMIMEType: navigationResponse.canShowMIMEType,
            isForMainFrame: navigationResponse.isForMainFrame,
            allowsSubframeDownload: allowsSubframeDownload,
            blocksInsecureHTTP: responseURL.map { browserShouldBlockInsecureHTTPURL($0) } ?? true
        )
    }

    static func responsePolicy(
        for response: URLResponse,
        canShowMIMEType: Bool,
        isForMainFrame: Bool,
        allowsSubframeDownload: Bool,
        blocksInsecureHTTP: Bool
    ) -> WKNavigationResponsePolicy {
        guard let scheme = response.url?.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return .allow
        }
        let contentDisposition = (response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Disposition")
        let downloadReason = BrowserDownloadFilenameResolver().navigationResponseDownloadReason(
            mimeType: response.mimeType,
            canShowMIMEType: canShowMIMEType,
            contentDisposition: contentDisposition,
            isForMainFrame: isForMainFrame
        )
        guard downloadReason != nil else { return .allow }
        if blocksInsecureHTTP || (!isForMainFrame && !allowsSubframeDownload) {
            return .cancel
        }
        return .download
    }

    func webView(
        _ webView: WKWebView,
        navigationAction: WKNavigationAction,
        didBecome download: WKDownload
    ) {
        retainDownloadDelegate(for: download)
    }

    func webView(
        _ webView: WKWebView,
        navigationResponse: WKNavigationResponse,
        didBecome download: WKDownload
    ) {
        retainDownloadDelegate(for: download)
    }

    private func retainDownloadDelegate(for download: WKDownload) {
        // WKDownload.delegate is weak. Tie the delegate to the download so a
        // transfer can finish after its originating popout window closes.
        objc_setAssociatedObject(
            download,
            &Self.downloadDelegateAssociationKey,
            downloadDelegate,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
        download.delegate = downloadDelegate
    }

}
