import AppKit
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
    private static var downloadDelegateAssociationKey: UInt8 = 0

    let window: NSWindow
    let webView: WKWebView
    private(set) lazy var tab = BrowserWebExtensionPopoutTab(controller: self)
    private weak var support: BrowserWebExtensionSupport?
    private(set) weak var extensionContext: WKWebExtensionContext?
    private let downloadDelegate: BrowserDownloadDelegate
    private let subframeDownloadIntents = BrowserSubframeDownloadIntentTracker()

    init(
        configuration: WKWebExtension.WindowConfiguration,
        context: WKWebExtensionContext,
        support: BrowserWebExtensionSupport
    ) {
        self.support = support
        self.extensionContext = context
        downloadDelegate = BrowserDownloadDelegate()

        let webViewConfiguration = context.webViewConfiguration ?? WKWebViewConfiguration()
        webView = WKWebView(frame: .zero, configuration: webViewConfiguration)
#if DEBUG
        webView.isInspectable = true
#endif

        let requestedFrame = configuration.frame
        let hasUsableOrigin = requestedFrame.origin.x.isFinite && requestedFrame.origin.y.isFinite
        let width = requestedFrame.width.isFinite && requestedFrame.width >= 50 ? requestedFrame.width : Self.defaultSize.width
        let height = requestedFrame.height.isFinite && requestedFrame.height >= 50 ? requestedFrame.height : Self.defaultSize.height
        let frame = CGRect(
            origin: hasUsableOrigin ? requestedFrame.origin : .zero,
            size: CGSize(width: width, height: height)
        )
        let usesFallbackFrame = !hasUsableOrigin
            || !requestedFrame.width.isFinite
            || !requestedFrame.height.isFinite
            || requestedFrame.width < 50
            || requestedFrame.height < 50
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
        if usesFallbackFrame {
            window.center()
        }

        super.init()
        downloadDelegate.savePanelParentWindow = { [weak window] in window }
        window.delegate = self
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

    var isKeyWindow: Bool {
        window.isKeyWindow
    }

    func owns(_ context: WKWebExtensionContext) -> Bool {
        extensionContext === context
    }

    func closeFromExtensionOrUser() {
        guard window.delegate === self else { return }
        window.delegate = nil
        support?.popoutDidClose(self)
        window.close()
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        window.delegate = nil
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

        let scheme = url.scheme?.lowercased()
        if scheme == "http" || scheme == "https" {
            if support?.openBrowserTab(
                url: nil,
                initialRequest: navigationAction.request,
                shouldActivate: true,
                webViewConfiguration: nil
            ) != nil {
                decisionHandler(.cancel)
                return
            }
            if !Self.canFallbackToExternalBrowser(for: navigationAction.request) ||
                !NSWorkspace.shared.open(url) {
                sentryCaptureWarning(
                    "browser.webExtension.popup.externalNavigationFailed",
                    category: "browser.webExtension",
                    data: ["scheme": scheme ?? "", "host": url.host ?? ""]
                )
            }
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
