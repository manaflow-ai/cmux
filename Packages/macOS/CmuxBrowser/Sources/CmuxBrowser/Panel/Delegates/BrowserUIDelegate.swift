public import WebKit
public import Foundation
internal import AppKit

/// `WKUIDelegate` for an embedded browser panel's `WKWebView`.
///
/// Lifted byte-faithfully out of the app target's `BrowserPanel`. Handles
/// `window.open()`/`target=_blank`/scripted popups, JavaScript dialogs
/// (alert/confirm/prompt), the `<input type="file">` open panel, and media
/// capture permission prompts. Panel reach-backs are injected closures
/// (``openInNewTab``, ``requestNavigation``, ``openPopup``, ``closeRequested``)
/// the owning `BrowserPanel` sets at construction. External-scheme routing,
/// in-page fallback loads, and alert presentation go through the injected
/// ``BrowserExternalNavigationPresenter``; the former `#if DEBUG`-guarded
/// `cmuxDebugLog` traces are surfaced through the injected ``logSink``.
///
/// `@MainActor`: every member touches main-thread-only WebKit/AppKit state
/// (`WKWebView`, `NSAlert`, `NSOpenPanel`, `NSTextField`, `NSApp.currentEvent`)
/// and is only ever invoked on WebKit's main-thread delegate callbacks, matching
/// the original app-target behavior.
@MainActor
public final class BrowserUIDelegate: NSObject, WKUIDelegate {
    /// Popup/new-tab routing policy shared with the navigation delegate.
    public let navigationPolicy = BrowserPopupNavigationPolicy()

    /// Routes external-scheme navigations, in-page fallback loads, and alert
    /// presentation. Injected so the localized alert copy resolves against the
    /// app catalog.
    public let externalNavigationPresenter: BrowserExternalNavigationPresenter

    /// Reports whether `webView` had a recent middle-click intent, used to bias
    /// new-tab routing. Injected because the underlying tracking lives in the
    /// app target's `CmuxWebView`; defaults to always-false.
    public var hasRecentMiddleClickIntent: @MainActor (WKWebView) -> Bool

    /// Opens `url` in a new tab.
    public var openInNewTab: ((URL) -> Void)?
    /// Requests a navigation for `request` with the given tab intent.
    public var requestNavigation: ((URLRequest, BrowserInsecureHTTPNavigationIntent) -> Void)?
    /// Presents an alert for `webView`. Defaults to the external-navigation
    /// presenter's sheet/modal presentation.
    public var presentAlert: BrowserExternalNavigationPresenter.AlertPresenter
    /// Creates and returns a live popup web view for a scripted popup, or `nil`
    /// when popup creation is unavailable.
    public var openPopup: ((WKWebViewConfiguration, WKWindowFeatures) -> WKWebView?)?
    /// Invoked when the page requests its own window be closed.
    public var closeRequested: ((WKWebView) -> Void)?

    /// Optional debug-log sink, invoked with the former `#if DEBUG`-guarded
    /// `cmuxDebugLog` trace messages. `nil` in release builds so the traces are
    /// compiled out at the wiring site, exactly as before.
    public var logSink: (@MainActor @Sendable (String) -> Void)?

    /// Creates a UI delegate. Callers assign the closure properties after
    /// construction.
    ///
    /// - Parameters:
    ///   - externalNavigationPresenter: Routes external-scheme navigation,
    ///     in-page fallback loads, and alert presentation.
    ///   - hasRecentMiddleClickIntent: Reports whether a web view had a recent
    ///     middle-click intent (defaults to always-false).
    public init(
        externalNavigationPresenter: BrowserExternalNavigationPresenter,
        hasRecentMiddleClickIntent: @escaping @MainActor (WKWebView) -> Bool = { _ in false }
    ) {
        self.externalNavigationPresenter = externalNavigationPresenter
        self.hasRecentMiddleClickIntent = hasRecentMiddleClickIntent
        self.presentAlert = { alert, webView, completion, cancel in
            externalNavigationPresenter.presentAlert(alert, in: webView, completion: completion, cancel: cancel)
        }
        super.init()
    }

    public func webViewDidClose(_ webView: WKWebView) {
        closeRequested?(webView)
    }

    private func javaScriptDialogTitle(for webView: WKWebView) -> String {
        if let absolute = webView.url?.absoluteString, !absolute.isEmpty {
            return String(localized: "browser.dialog.pageSaysAt", defaultValue: "The page at \(absolute) says:")
        }
        return String(localized: "browser.dialog.pageSays", defaultValue: "This page says:")
    }

    private func presentDialog(
        _ alert: NSAlert,
        for webView: WKWebView,
        completion: @escaping (NSApplication.ModalResponse) -> Void,
        cancel: @escaping () -> Void
    ) {
        presentAlert(alert, webView, completion, cancel)
    }

    /// Called when the page requests a new window (window.open(), target=_blank, etc.).
    ///
    /// Returns a live popup WKWebView created with WebKit's supplied configuration
    /// to preserve popup browsing-context semantics (window.opener, postMessage).
    /// Falls back to new-tab behavior only if popup creation is unavailable.
    public func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
#if DEBUG
        let currentEventType = NSApp.currentEvent.map { String(describing: $0.type) } ?? "nil"
        let currentEventButton = NSApp.currentEvent.map { String($0.buttonNumber) } ?? "nil"
        let navType = String(describing: navigationAction.navigationType)
        let requestMethod = navigationAction.request.httpMethod ?? "nil"
        let requestURL = navigationAction.request.url?.absoluteString ?? "nil"
        let targetMainFrame = navigationAction.targetFrame.map { $0.isMainFrame ? "1" : "0" } ?? "nil"
        let windowFeaturesSummary = [
            "x=\(windowFeatures.x?.stringValue ?? "nil")",
            "y=\(windowFeatures.y?.stringValue ?? "nil")",
            "w=\(windowFeatures.width?.stringValue ?? "nil")",
            "h=\(windowFeatures.height?.stringValue ?? "nil")",
            "toolbars=\(windowFeatures.toolbarsVisibility?.stringValue ?? "nil")",
            "resizable=\(windowFeatures.allowsResizing?.stringValue ?? "nil")",
            "status=\(windowFeatures.statusBarVisibility?.stringValue ?? "nil")",
            "menu=\(windowFeatures.menuBarVisibility?.stringValue ?? "nil")"
        ].joined(separator: ",")
        logSink?(
            "browser.nav.createWebView navType=\(navType) button=\(navigationAction.buttonNumber) " +
            "mods=\(navigationAction.modifierFlags.rawValue) targetNil=\(navigationAction.targetFrame == nil ? 1 : 0) " +
            "targetMain=\(targetMainFrame) method=\(requestMethod) url=\(requestURL) " +
            "eventType=\(currentEventType) eventButton=\(currentEventButton) " +
            "windowFeatures={\(windowFeaturesSummary)}"
        )
#endif
        // External URL schemes → hand off to macOS, don't create a popup
        if let url = navigationAction.request.url,
           externalNavigationPresenter.resolver.shouldRouteExternalNavigation(url) {
            externalNavigationPresenter.handleExternalNavigation(
                url,
                source: "uiDelegate",
                webView: webView,
                loadFallbackRequest: { [requestNavigation] request in
                    requestNavigation?(request, .currentTab)
                },
                presentAlert: presentAlert
            )
            return nil
        }

        let hasRecentMiddleClickIntent = self.hasRecentMiddleClickIntent(webView)
        let popupFeaturesWereSpecified = navigationPolicy.popupFeaturesWereSpecified(windowFeatures: windowFeatures)
        let shouldOpenSimpleUserGesturePopupInCurrentTab = navigationPolicy.shouldOpenSimpleUserGesturePopupInCurrentTab(
            navigationType: navigationAction.navigationType,
            requestMethod: navigationAction.request.httpMethod,
            requestURL: navigationAction.request.url,
            openerURL: webView.url,
            modifierFlags: navigationAction.modifierFlags,
            buttonNumber: navigationAction.buttonNumber,
            hasRecentMiddleClickIntent: hasRecentMiddleClickIntent,
            popupFeaturesWereSpecified: popupFeaturesWereSpecified
        )

        if shouldOpenSimpleUserGesturePopupInCurrentTab {
            if let url = navigationAction.request.url {
#if DEBUG
                logSink?(
                    "browser.nav.createWebView.action kind=requestNavigationSimpleUserGesture intent=currentTab " +
                    "url=\(navigationPolicy.debugURL(url))"
                )
#endif
                if let requestNavigation {
                    requestNavigation(navigationAction.request, .currentTab)
                } else {
                    externalNavigationPresenter.loadRequest(navigationAction.request, in: webView)
                }
            }
            return nil
        }

        // Only treat scripted `.other` requests as popups when WebKit surfaced
        // explicit window features; bare `_blank` falls through to tabs.
        let isScriptedPopup = navigationPolicy.shouldCreatePopup(
            navigationType: navigationAction.navigationType,
            modifierFlags: navigationAction.modifierFlags,
            buttonNumber: navigationAction.buttonNumber,
            popupFeaturesWereSpecified: popupFeaturesWereSpecified,
            hasRecentMiddleClickIntent: hasRecentMiddleClickIntent
        )

        if isScriptedPopup, let popupWebView = openPopup?(configuration, windowFeatures) {
#if DEBUG
            logSink?("browser.nav.createWebView.action kind=popup")
#endif
            return popupWebView
        }

        // Fallback: open in new tab (no opener linkage)
        if let url = navigationAction.request.url {
            if let requestNavigation {
                let intent: BrowserInsecureHTTPNavigationIntent = .newTab
#if DEBUG
                logSink?(
                    "browser.nav.createWebView.action kind=requestNavigation intent=newTab " +
                    "url=\(navigationPolicy.debugURL(url))"
                )
#endif
                requestNavigation(navigationAction.request, intent)
            } else {
#if DEBUG
                logSink?("browser.nav.createWebView.action kind=openInNewTab url=\(url.absoluteString)")
#endif
                openInNewTab?(url)
            }
        }
        return nil
    }

    /// Handle <input type="file"> elements by presenting the native file picker.
    public func webView(
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

    public func webView(
        _ webView: WKWebView,
        requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType,
        decisionHandler: @escaping (WKPermissionDecision) -> Void
    ) {
        decisionHandler(.prompt)
    }

    public func webView(
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
        presentDialog(
            alert,
            for: webView,
            completion: { _ in completionHandler() },
            cancel: completionHandler
        )
    }

    public func webView(
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
        presentDialog(
            alert,
            for: webView,
            completion: { response in
                completionHandler(response == .alertFirstButtonReturn)
            },
            cancel: {
                completionHandler(false)
            }
        )
    }

    public func webView(
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

        presentDialog(
            alert,
            for: webView,
            completion: { response in
                if response == .alertFirstButtonReturn {
                    completionHandler(field.stringValue)
                } else {
                    completionHandler(nil)
                }
            },
            cancel: {
                completionHandler(nil)
            }
        )
    }
}
