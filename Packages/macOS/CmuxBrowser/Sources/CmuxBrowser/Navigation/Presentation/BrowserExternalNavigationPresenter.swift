public import AppKit
public import Foundation
public import WebKit
#if DEBUG
internal import CMUXDebugLog
#endif

/// Presents the AppKit/WebKit alerts and loads requests for browser navigation
/// that the embedded web view cannot keep in-page.
///
/// This owns the side-effecting half of external navigation: preparing a
/// `URLRequest` for an ordinary load, loading file and remote requests into a
/// `WKWebView`, finding the visible host window an alert can attach to, and
/// running the "open in another app?" confirmation and the "could not open
/// link" failure alerts. The pure routing decision (whether a URL is external
/// and how) lives in ``BrowserExternalNavigationResolver``; this presenter holds
/// a resolver and a policy and acts on their results.
///
/// It is a `@MainActor` value type rather than a bag of free functions because
/// every member touches main-thread-only AppKit/WebKit state (`NSAlert`,
/// `NSWorkspace`, `NSPasteboard`, `NSApp`, `WKWebView`). The localized alert
/// copy is injected as ``BrowserExternalNavigationStrings`` so it resolves
/// against the app's catalog rather than the package bundle.
@MainActor
public struct BrowserExternalNavigationPresenter {
    /// Strategy for displaying an `NSAlert`, parameterized so callers can attach
    /// the alert as a sheet on a host window or inject a test double.
    ///
    /// The closure receives the alert, the originating web view, a completion
    /// invoked with the chosen modal response, and a cancel invoked when the
    /// alert is dismissed without a response.
    public typealias AlertPresenter = (
        _ alert: NSAlert,
        _ webView: WKWebView,
        _ completion: @escaping (NSApplication.ModalResponse) -> Void,
        _ cancel: @escaping () -> Void
    ) -> Void

    /// The localized alert copy, resolved app-side and injected so non-English
    /// translations are not dropped.
    public let strings: BrowserExternalNavigationStrings

    /// The pure routing decision used by ``handleExternalNavigation(_:source:webView:loadFallbackRequest:presentAlert:)``.
    public let resolver: BrowserExternalNavigationResolver

    /// The popup-navigation policy whose ``BrowserPopupNavigationPolicy/debugURL(_:)``
    /// renders URLs for the `#if DEBUG` navigation logging.
    public let policy: BrowserPopupNavigationPolicy

    /// Creates a presenter.
    ///
    /// - Parameters:
    ///   - strings: The localized alert copy, resolved against the app catalog.
    ///   - resolver: The external-navigation routing decision (defaults to the
    ///     standard embedded-scheme resolver).
    ///   - policy: The popup-navigation policy used only for DEBUG URL rendering.
    public init(
        strings: BrowserExternalNavigationStrings,
        resolver: BrowserExternalNavigationResolver = BrowserExternalNavigationResolver(),
        policy: BrowserPopupNavigationPolicy = BrowserPopupNavigationPolicy()
    ) {
        self.strings = strings
        self.resolver = resolver
        self.policy = policy
    }

    /// Returns a copy of `request` configured for an ordinary load while
    /// preserving its method, body, and headers.
    public func preparedNavigationRequest(_ request: URLRequest) -> URLRequest {
        var preparedRequest = request
        // Match browser behavior for ordinary loads while preserving method/body/headers.
        preparedRequest.cachePolicy = .useProtocolCachePolicy
        return preparedRequest
    }

    /// Returns the directory URL WebKit must be granted read access to in order
    /// to load `fileURL`, or `nil` when the URL is not an absolute file URL.
    ///
    /// - Parameters:
    ///   - fileURL: The local file URL about to be loaded.
    ///   - fileManager: The file manager used to probe whether `fileURL` is a
    ///     directory (defaults to `.default`).
    public func readAccessURL(forLocalFileURL fileURL: URL, fileManager: FileManager = .default) -> URL? {
        guard fileURL.isFileURL, fileURL.path.hasPrefix("/") else { return nil }
        let path = fileURL.path
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
            return fileURL
        }

        let parent = fileURL.deletingLastPathComponent()
        guard !parent.path.isEmpty, parent.path.hasPrefix("/") else { return nil }
        return parent
    }

    /// Loads `request` into `webView`, granting file read access for file URLs
    /// and preparing the request for remote loads.
    @discardableResult
    public func loadRequest(_ request: URLRequest, in webView: WKWebView) -> WKNavigation? {
        guard let url = request.url else { return nil }
        if url.isFileURL {
            guard let readAccessURL = readAccessURL(forLocalFileURL: url) else { return nil }
            return webView.loadFileURL(url, allowingReadAccessTo: readAccessURL)
        }
        return webView.load(preparedNavigationRequest(request))
    }

    /// Copies `url` to the general pasteboard.
    private func copyExternalNavigationURL(_ url: URL) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }

    /// Returns `window` only when it is a visible, interactive window an alert
    /// sheet can attach to, or `nil` otherwise.
    public func interactiveModalHostWindow(_ window: NSWindow?) -> NSWindow? {
        guard let window else { return nil }
        guard window.isVisible else { return nil }
        guard window.alphaValue > 0 else { return nil }
        guard !window.ignoresMouseEvents else { return nil }
        guard !window.isExcludedFromWindowsMenu else { return nil }
        return window
    }

    /// Returns the interactive host window for `webView`, or `nil` when its
    /// window is not currently a valid sheet host.
    public func interactiveModalHostWindow(for webView: WKWebView) -> NSWindow? {
        interactiveModalHostWindow(webView.window)
    }

    /// Returns a fallback interactive host window from the app's key or main
    /// window when the originating web view has no valid host.
    public func fallbackInteractiveModalHostWindow() -> NSWindow? {
        if let keyWindow = interactiveModalHostWindow(NSApp.keyWindow) {
            return keyWindow
        }
        return interactiveModalHostWindow(NSApp.mainWindow)
    }

    /// Presents `alert` as a sheet on the web view's host window when one is
    /// available, otherwise runs it modally.
    ///
    /// - Parameters:
    ///   - alert: The alert to display.
    ///   - webView: The web view whose window the sheet attaches to.
    ///   - completion: Invoked with the chosen modal response.
    ///   - cancel: Invoked when the alert is dismissed without a response.
    public func presentAlert(
        _ alert: NSAlert,
        in webView: WKWebView,
        completion: @escaping (NSApplication.ModalResponse) -> Void,
        cancel: @escaping () -> Void = {}
    ) {
        _ = cancel
        if let window = interactiveModalHostWindow(for: webView) {
            alert.beginSheetModal(for: window, completionHandler: completion)
            return
        }
        completion(alert.runModal())
    }

    /// Asks the user whether to open `url` in another app, calling `completion`
    /// with `true` when they confirm and `false` otherwise.
    private func presentExternalNavigationPrompt(
        for url: URL,
        in webView: WKWebView,
        completion: @escaping (Bool) -> Void,
        presentAlert: AlertPresenter
    ) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = strings.openPromptTitle
        alert.informativeText = strings.openPromptMessage
        alert.addButton(withTitle: strings.openPromptOpenAppButton)
        alert.addButton(withTitle: strings.openPromptStayInBrowserButton)

        let handleResponse: (NSApplication.ModalResponse) -> Void = { response in
            completion(response == .alertFirstButtonReturn)
        }

        presentAlert(alert, webView, handleResponse) {
            completion(false)
        }
    }

    /// Reports that `url` could not be opened, offering to copy the link.
    private func presentExternalNavigationFailure(
        for url: URL,
        in webView: WKWebView,
        presentAlert: AlertPresenter
    ) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = strings.openFailureTitle
        alert.informativeText = strings.openFailureMessage
        alert.addButton(withTitle: strings.okButton)
        alert.addButton(withTitle: strings.copyLinkButton)

        let handleResponse: (NSApplication.ModalResponse) -> Void = { response in
            if response == .alertSecondButtonReturn {
                copyExternalNavigationURL(url)
            }
        }

        presentAlert(alert, webView, handleResponse) {}
    }

    /// Hands `url` to macOS via `NSWorkspace`, presenting the failure alert when
    /// the system cannot open it. Returns whether the open succeeded.
    @discardableResult
    private func openExternalNavigationURL(
        _ url: URL,
        source: String,
        webView: WKWebView,
        presentAlert: AlertPresenter
    ) -> Bool {
        let opened = NSWorkspace.shared.open(url)
        if !opened {
            presentExternalNavigationFailure(for: url, in: webView, presentAlert: presentAlert)
        }
#if DEBUG
        CMUXDebugLog.logDebugEvent(
            "browser.navigation.external source=\(source) opened=\(opened ? 1 : 0) " +
            "url=\(policy.debugURL(url))"
        )
#endif
        return opened
    }

    /// Routes a navigation `url` that the embedded web view cannot display:
    /// loads an extracted `http(s)` fallback in-page, or prompts to open the
    /// deeplink in its native app. Returns whether the URL was handled
    /// externally (`false` means it should stay in the web view).
    ///
    /// - Parameters:
    ///   - url: The navigation URL.
    ///   - source: A short tag identifying the navigation source for logging.
    ///   - webView: The originating web view.
    ///   - loadFallbackRequest: Loads the extracted fallback request in-page.
    ///   - presentAlert: Strategy for displaying the confirmation/failure alerts
    ///     (defaults to ``presentAlert(_:in:completion:cancel:)``).
    @discardableResult
    public func handleExternalNavigation(
        _ url: URL,
        source: String,
        webView: WKWebView,
        loadFallbackRequest: (URLRequest) -> Void,
        presentAlert: @escaping AlertPresenter
    ) -> Bool {
        guard let action = resolver.externalNavigationAction(for: url) else { return false }

        switch action {
        case let .browserFallback(fallbackURL):
            let request = URLRequest(url: fallbackURL)
            loadFallbackRequest(request)
#if DEBUG
            CMUXDebugLog.logDebugEvent(
                "browser.navigation.external source=\(source) opened=1 fallback=1 " +
                "fallbackURL=\(policy.debugURL(fallbackURL)) url=\(policy.debugURL(url))"
            )
#endif
            return true

        case let .promptToOpenApp(externalURL):
            presentExternalNavigationPrompt(
                for: externalURL,
                in: webView,
                completion: { shouldOpenApp in
                    guard shouldOpenApp else {
#if DEBUG
                        CMUXDebugLog.logDebugEvent(
                            "browser.navigation.external source=\(source) opened=0 prompt=1 allowed=0 " +
                            "url=\(policy.debugURL(externalURL))"
                        )
#endif
                        return
                    }
                    openExternalNavigationURL(
                        externalURL,
                        source: source,
                        webView: webView,
                        presentAlert: presentAlert
                    )
                },
                presentAlert: presentAlert
            )
            return true
        }
    }
}
