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

    /// Creates a browser view bound to a surface state.
    /// - Parameter state: The browser surface state to host.
    public init(state: BrowserSurfaceState) {
        self.state = state
    }

    /// Builds the coordinator that owns the web view and its observations.
    /// - Returns: A new ``Coordinator``.
    public func makeCoordinator() -> Coordinator {
        Coordinator(state: state)
    }

    /// Creates and configures the hosted `WKWebView`.
    /// - Parameter context: The representable context carrying the coordinator.
    /// - Returns: The configured web view.
    public func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // Default persistent data store: cookies/localStorage persist on the
        // phone across launches. Cross-device sync with the Mac is P2.
        configuration.websiteDataStore = .default()
        configuration.allowsInlineMediaPlayback = true
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        context.coordinator.attach(webView: webView)
        return webView
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
        private weak var webView: WKWebView?
        private var observations: [NSKeyValueObservation] = []

        /// Creates a coordinator for a surface state.
        /// - Parameter state: The surface state to mirror web-view changes into.
        public init(state: BrowserSurfaceState) {
            self.state = state
            super.init()
        }

        /// Binds the coordinator to a web view: registers key-value observations
        /// and kicks off the first pending load.
        /// - Parameter webView: The web view to observe and drive.
        func attach(webView: WKWebView) {
            self.webView = webView
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
                webView.load(URLRequest(url: restore))
            }
        }

        /// Runs any pending load request and navigation command from the state
        /// against the web view.
        func applyPendingWork() {
            guard let webView else { return }
            if let url = state.consumeLoadRequest() {
                webView.load(URLRequest(url: url))
            }
            if let command = state.consumeCommand() {
                run(command, on: webView)
            }
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
            webView?.navigationDelegate = nil
            webView?.uiDelegate = nil
            webView = nil
        }

        private func observe(_ webView: WKWebView) {
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
                webView.observe(\.url) { [state] webView, _ in
                    MainActor.assumeIsolated {
                        state.currentURL = webView.url
                        // Do not clobber the user's in-progress typing: only
                        // mirror the live URL into the address bar when the user
                        // is not editing it.
                        if let url = webView.url, !state.isAddressEditing {
                            state.addressText = url.absoluteString
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
        }

        public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            state.navigationDidFinish()
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
                webView.load(navigationAction.request)
            }
            return nil
        }
    }
}
#endif
