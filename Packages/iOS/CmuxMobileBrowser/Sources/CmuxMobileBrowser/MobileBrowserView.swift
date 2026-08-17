#if canImport(UIKit)
public import SwiftUI
public import UIKit
public import WebKit

/// SwiftUI wrapper that hosts a single `WKWebView` for a ``BrowserSurfaceState``.
///
/// This is the browser sibling of the terminal's `GhosttySurfaceRepresentable`:
/// a `UIViewRepresentable` whose coordinator owns the web view, observes its
/// navigation key paths, and mirrors them into the `@Observable` surface state
/// so the SwiftUI chrome (address bar, progress, back/forward) stays in sync.
///
/// Loading progress and navigation flags come from `NSKeyValueObservation` on
/// the web view plus `WKNavigationDelegate` callbacks rather than Combine, to
/// fit the `@Observable` model and avoid `ObservableObject`.
public struct MobileBrowserView: UIViewRepresentable {
    /// The state this view drives and reflects.
    public let state: BrowserSurfaceState
    private let localURLCodec: MobileBrowserLocalURLCodec
    private let onDiagnosticEvent: @MainActor (BrowserSurfaceDiagnosticEvent) -> Void

    /// Creates a browser view bound to a surface state.
    /// - Parameter state: The browser surface state to host.
    public init(
        state: BrowserSurfaceState,
        localURLCodec: MobileBrowserLocalURLCodec = MobileBrowserLocalURLCodec(),
        onDiagnosticEvent: @escaping @MainActor (BrowserSurfaceDiagnosticEvent) -> Void = { _ in }
    ) {
        self.state = state
        self.localURLCodec = localURLCodec
        self.onDiagnosticEvent = onDiagnosticEvent
    }

    /// Builds the coordinator that owns the web view and its observations.
    /// - Returns: A new ``Coordinator``.
    public func makeCoordinator() -> Coordinator {
        Coordinator(
            state: state,
            localURLCodec: localURLCodec,
            onDiagnosticEvent: onDiagnosticEvent
        )
    }

    /// Creates and configures the hosted `WKWebView`.
    /// - Parameter context: The representable context carrying the coordinator.
    /// - Returns: The configured web view.
    public func makeUIView(context: Context) -> WKWebView {
        let localSchemeHandler = makeLocalSchemeHandler()
        let webView = Self.makeConfiguredWebView(
            localSchemeHandler: localSchemeHandler,
            localURLCodec: localURLCodec
        )
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        context.coordinator.attach(webView: webView, localSchemeHandler: localSchemeHandler)
        return webView
    }

    /// Builds the hosted web view with the surface's fixed configuration,
    /// independent of the SwiftUI `Context` so the gesture policy can be
    /// unit-tested.
    static func makeConfiguredWebView(
        localSchemeHandler: MobileBrowserLocalSchemeHandler? = nil,
        localURLCodec: MobileBrowserLocalURLCodec = MobileBrowserLocalURLCodec()
    ) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // Default persistent data store: cookies/localStorage persist on the
        // phone across launches. Cross-device sync with the Mac is P2.
        configuration.websiteDataStore = .default()
        if let localSchemeHandler {
            configuration.setURLSchemeHandler(
                localSchemeHandler,
                forURLScheme: localURLCodec.scheme
            )
        }
        configuration.allowsInlineMediaPlayback = true
        let webView = WKWebView(frame: .zero, configuration: configuration)
        // Off, by design: the browser pane is pushed onto the workspace
        // `NavigationStack`, and the web view's own left-edge back-swipe would
        // otherwise eat the standard iOS edge swipe that returns to the workspace
        // list (issue #6634). Web history stays reachable through the chrome
        // bar's back/forward buttons.
        webView.allowsBackForwardNavigationGestures = false
        return webView
    }

    private func makeLocalSchemeHandler() -> MobileBrowserLocalSchemeHandler? {
        guard let panelID = state.localPanelID,
              let loader = state.localResourceLoader else { return nil }
        return MobileBrowserLocalSchemeHandler(
            panelID: panelID,
            loader: loader,
            urlCodec: localURLCodec,
            onFetchStarted: { [state] in state.localFetchDidStart() },
            onFetchProgress: { [state] progress in state.localFetchDidProgress(progress) },
            onFetchFinished: { [state] in state.localFetchDidFinish() },
            onFetchFailed: { [state] _ in state.localFetchDidFail() }
        )
    }

    /// Pushes any pending load request and navigation command from the state
    /// into the web view.
    /// - Parameters:
    ///   - uiView: The hosted web view.
    ///   - context: The representable context carrying the coordinator.
    public func updateUIView(_ uiView: WKWebView, context: Context) {
        context.coordinator.applyPendingWork()
    }

    /// Tears down the coordinator's observations and web-view delegate.
    /// - Parameters:
    ///   - uiView: The hosted web view.
    ///   - coordinator: The coordinator to detach.
    public static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        coordinator.detach()
    }

    /// Owns the `WKWebView`, observes its navigation key paths, and bridges
    /// navigation callbacks into the `@Observable` ``BrowserSurfaceState``.
    @MainActor
    public final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        private let state: BrowserSurfaceState
        private let localURLCodec: MobileBrowserLocalURLCodec
        private let onDiagnosticEvent: @MainActor (BrowserSurfaceDiagnosticEvent) -> Void
        private weak var webView: WKWebView?
        private var localSchemeHandler: MobileBrowserLocalSchemeHandler?
        private var observations: [NSKeyValueObservation] = []

        /// Creates a coordinator for a surface state.
        /// - Parameter state: The surface state to mirror web-view changes into.
        public init(
            state: BrowserSurfaceState,
            localURLCodec: MobileBrowserLocalURLCodec,
            onDiagnosticEvent: @escaping @MainActor (BrowserSurfaceDiagnosticEvent) -> Void = { _ in }
        ) {
            self.state = state
            self.localURLCodec = localURLCodec
            self.onDiagnosticEvent = onDiagnosticEvent
            super.init()
        }

        /// Binds the coordinator to a web view: registers key-value observations
        /// and kicks off the first pending load.
        /// - Parameter webView: The web view to observe and drive.
        func attach(
            webView: WKWebView,
            localSchemeHandler: MobileBrowserLocalSchemeHandler?
        ) {
            self.webView = webView
            self.localSchemeHandler = localSchemeHandler
            observe(webView)
            // A surface can be re-attached to a fresh WKWebView when SwiftUI
            // remounts the representable (switching workspaces, hiding/showing
            // the browser). The surface state survives, but the web view does
            // not, so restore the last committed URL on re-attach to honor the
            // "current page is restored on return" promise. First mount already
            // has a pending initial-URL load, so guard against a double-load.
            let hadPendingLoad = state.loadRequest != nil
            applyPendingWork()
            if !hadPendingLoad, webView.url == nil, let restore = state.currentURL {
                load(restore, in: webView)
            }
        }

        /// Runs any pending load request and navigation command from the state
        /// against the web view.
        func applyPendingWork() {
            guard let webView else { return }
            if let url = state.consumeLoadRequest() {
                load(url, in: webView)
            }
            if let command = state.consumeCommand() {
                run(command, on: webView)
            }
        }

        private func load(_ url: URL, in webView: WKWebView) {
            let requestURL = localRequestURL(for: url) ?? url
            if requestURL.scheme?.caseInsensitiveCompare(localURLCodec.scheme) == .orderedSame {
                localSchemeHandler?.beginPageLoad()
            }
            webView.load(URLRequest(url: requestURL))
        }

        private func localRequestURL(for url: URL) -> URL? {
            guard url.isFileURL,
                  let panelID = state.localPanelID,
                  localSchemeHandler != nil else { return nil }
            return localURLCodec.make(
                panelID: panelID,
                path: "/" + url.lastPathComponent
            )
        }

        private func run(_ command: BrowserSurfaceState.NavigationCommand, on webView: WKWebView) {
            switch command {
            case .goBack:
                webView.goBack()
            case .goForward:
                webView.goForward()
            case .reload:
                webView.reload()
            case .stopLoading:
                webView.stopLoading()
            }
        }

        /// Cancels all observations and releases the web view. Called on
        /// dismantle so the surface leaves no dangling KVO registrations.
        func detach() {
            observations.forEach { $0.invalidate() }
            observations.removeAll()
            localSchemeHandler?.cancelAll()
            localSchemeHandler = nil
            webView?.navigationDelegate = nil
            webView?.uiDelegate = nil
            webView = nil
        }

        private func observe(_ webView: WKWebView) {
            let localScheme = localURLCodec.scheme
            // Each observer mirrors one web-view property into the @Observable
            // state on the main actor. `options: [.initial]` is intentionally
            // omitted so the seeded state is not overwritten before first load.
            observations = [
                webView.observe(\.estimatedProgress) { [state] webView, _ in
                    MainActor.assumeIsolated {
                        state.estimatedProgress = webView.estimatedProgress
                    }
                },
                webView.observe(\.title) { [state] webView, _ in
                    MainActor.assumeIsolated {
                        if let title = webView.title, !title.isEmpty {
                            state.title = title
                        }
                    }
                },
                webView.observe(\.url) { [state, localScheme] webView, _ in
                    MainActor.assumeIsolated {
                        guard let observedURL = webView.url,
                              observedURL.scheme?.caseInsensitiveCompare(localScheme) != .orderedSame else {
                            return
                        }
                        state.currentURL = observedURL
                        // Do not clobber the user's in-progress typing: only
                        // mirror the live URL into the address bar when the user
                        // is not editing it.
                        if !state.isAddressEditing {
                            state.addressText = observedURL.absoluteString
                        }
                    }
                },
                webView.observe(\.canGoBack) { [state] webView, _ in
                    MainActor.assumeIsolated { state.canGoBack = webView.canGoBack }
                },
                webView.observe(\.canGoForward) { [state] webView, _ in
                    MainActor.assumeIsolated { state.canGoForward = webView.canGoForward }
                },
            ]
        }

        // MARK: - WKNavigationDelegate

        public func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            state.navigationDidStart()
            onDiagnosticEvent(.navigateStarted)
        }

        public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            state.navigationDidFinish()
            onDiagnosticEvent(.navigateSucceeded)
            if let title = webView.title, !title.isEmpty {
                state.title = title
            }
        }

        public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
            failNavigation(with: error)
        }

        public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
            failNavigation(with: error)
        }

        private func failNavigation(with error: any Error) {
            // A cancelled load reports `NSURLErrorCancelled`. This is not a
            // failure to surface; it happens on a user stop AND when a new
            // navigation replaces an in-flight one. Mirror the web view's real
            // `isLoading` rather than forcing `false`, so the chrome stays in the
            // loading state when a replacement navigation is still in flight.
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled {
                state.isLoading = webView?.isLoading ?? false
                if !state.isLoading { state.estimatedProgress = 0 }
                return
            }
            state.navigationDidFail(message: error.localizedDescription)
            if webView?.url?.scheme?.caseInsensitiveCompare(localURLCodec.scheme) == .orderedSame {
                state.localFetchDidFail()
            }
            onDiagnosticEvent(.navigateFailed(error))
        }

        // MARK: - WKUIDelegate

        public func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            // P1 is a single-pane browser with no tabs, so `target="_blank"` /
            // `window.open` links (which arrive with a nil `targetFrame`) would
            // otherwise be silently dropped. Load them in the current web view
            // instead so external/doc/auth links still navigate. Returning nil
            // tells WebKit not to create a new web view.
            if navigationAction.targetFrame == nil {
                if let url = navigationAction.request.url,
                   let localURL = localRequestURL(for: url) {
                    localSchemeHandler?.beginPageLoad()
                    webView.load(URLRequest(url: localURL))
                } else {
                    webView.load(navigationAction.request)
                }
            }
            return nil
        }
    }
}
#endif
