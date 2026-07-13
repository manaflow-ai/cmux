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
    /// The authenticated scope's isolated cookie and website-data container.
    public let websiteDataStore: WKWebsiteDataStore

    /// Creates a browser view bound to a surface state.
    /// - Parameters:
    ///   - state: The browser surface state to host.
    ///   - websiteDataStore: The authenticated scope's WebKit data container.
    public init(state: BrowserSurfaceState, websiteDataStore: WKWebsiteDataStore) {
        self.state = state
        self.websiteDataStore = websiteDataStore
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
        let webView = makeConfiguredWebView()
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        context.coordinator.attach(webView: webView)
        return webView
    }

    /// Builds the hosted web view with the surface's fixed configuration,
    /// independent of the SwiftUI `Context` so the gesture policy can be
    /// unit-tested.
    func makeConfiguredWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = websiteDataStore
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
        let pageMetadataCoalescer: BrowserPageMetadataEventCoalescer
        private weak var webView: WKWebView?
        private var observations: [NSKeyValueObservation] = []

        /// Creates a coordinator for a surface state.
        /// - Parameter state: The surface state to mirror web-view changes into.
        public init(state: BrowserSurfaceState) {
            self.state = state
            self.pageMetadataCoalescer = BrowserPageMetadataEventCoalescer { [weak state] update in
                state?.applyPageMetadataUpdate(update)
            }
            super.init()
        }

        /// Binds the coordinator to a web view: registers key-value observations
        /// and kicks off the first pending load.
        /// - Parameter webView: The web view to observe and drive.
        func attach(webView: WKWebView) {
            if self.webView != nil, self.webView !== webView {
                detach()
            }
            self.webView = webView
            observe(webView)
            // WebKit's `.recommended` content mode resolves to desktop on
            // iPad-class devices. Inject that resolution so the desktop-site
            // menu label and toggle direction are correct on first use.
            state.recommendedContentModeIsDesktop =
                UIDevice.current.userInterfaceIdiom == .pad
            let pendingLoadURL = state.consumeLoadRequest()
            // A fresh web view starts idle, but the surface may still carry
            // `isLoading` from a navigation that was in flight when the old
            // web view was torn down. Keep the synchronous loading state for a
            // pending destination; otherwise mirror the fresh web view so a
            // stale progress line does not persist.
            if pendingLoadURL == nil {
                state.isLoading = webView.isLoading
            }
            state.estimatedProgress = webView.estimatedProgress
            mirrorNavigationCapabilities(from: webView)

            // An explicit pending load (first mount's initial URL, or a load
            // queued while unmounted) wins outright. A command queued before
            // the remount targeted the old web view's history and would cancel
            // or no-op against this fresh load, so drop it.
            if let url = pendingLoadURL {
                webView.load(URLRequest(url: url))
                _ = state.consumeCommand()
                return
            }

            // A surface can be re-attached to a fresh WKWebView when SwiftUI
            // remounts the representable (switching workspaces, hiding/showing
            // the browser). The surface state survives, but the web view does
            // not, so restore the saved WebKit interaction state to preserve
            // the page and back/forward stack. If WebKit rejects that state,
            // fall back to the last committed URL.
            let restoredInteractionState = restoreInteractionState(on: webView)
            mirrorNavigationCapabilities(from: webView)
            if !restoredInteractionState, let restore = state.currentURL {
                webView.load(URLRequest(url: restore))
            }

            // Apply a command queued while no web view was attached (e.g. the
            // desktop-site toggle's reload) after the session is restored so
            // it acts on the restored page, not an empty web view.
            if let command = state.consumeCommand() {
                run(command, on: webView)
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
            // No interaction-state capture here: right after `goBack()`/
            // `goForward()` the snapshot still reflects the previous history
            // position. `didFinish` captures the committed result, and
            // `detach()` captures whatever WebKit has if the pane is torn
            // down mid-navigation.
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
            if let webView {
                pageMetadataCoalescer.receiveTitle(webView.title)
                if !webView.isLoading, let url = webView.url {
                    pageMetadataCoalescer.receiveURL(url)
                }
                pageMetadataCoalescer.flush()
                captureInteractionState(from: webView)
            } else {
                pageMetadataCoalescer.flush()
            }
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
                webView.observe(\.estimatedProgress) { [weak self, state] webView, _ in
                    MainActor.assumeIsolated {
                        guard self?.acceptsCallbacks(from: webView) == true else { return }
                        state.estimatedProgress = webView.estimatedProgress
                    }
                },
                webView.observe(\.title) { [weak self, state] webView, _ in
                    MainActor.assumeIsolated {
                        guard self?.acceptsCallbacks(from: webView) == true else { return }
                        self?.pageMetadataCoalescer.receiveTitle(webView.title)
                    }
                },
                webView.observe(\.url) { [weak self, state] webView, _ in
                    MainActor.assumeIsolated {
                        guard self?.acceptsCallbacks(from: webView) == true else { return }
                        guard let url = webView.url else { return }
                        if !webView.isLoading {
                            // History API and same-document navigation update
                            // `url` without a matching `didFinish` callback.
                            self?.pageMetadataCoalescer.receiveURL(url)
                        } else if !state.isAddressEditing {
                            // Mirror provisional destinations into the address
                            // bar without persisting them as committed pages.
                            state.addressText = url.absoluteString
                        }
                    }
                },
                webView.observe(\.canGoBack) { [weak self, state] webView, _ in
                    MainActor.assumeIsolated {
                        guard self?.acceptsCallbacks(from: webView) == true else { return }
                        state.canGoBack = webView.canGoBack
                    }
                },
                webView.observe(\.canGoForward) { [weak self, state] webView, _ in
                    MainActor.assumeIsolated {
                        guard self?.acceptsCallbacks(from: webView) == true else { return }
                        state.canGoForward = webView.canGoForward
                    }
                },
            ]
        }

        private func acceptsCallbacks(from candidate: WKWebView) -> Bool {
            webView === candidate
        }

        private func mirrorNavigationCapabilities(from webView: WKWebView) {
            state.canGoBack = webView.canGoBack
            state.canGoForward = webView.canGoForward
        }

        private func restoreInteractionState(on webView: WKWebView) -> Bool {
            guard let savedInteractionState = state.savedInteractionState else { return false }
            webView.interactionState = savedInteractionState
            // WebKit populates the back/forward list synchronously when it
            // accepts a snapshot but may commit the page load asynchronously,
            // so `webView.url` alone can still be nil for a successful
            // restore. Only report failure (triggering the `currentURL`
            // fallback) when WebKit rejected the snapshot outright.
            return webView.url != nil || webView.backForwardList.currentItem != nil
        }

        private func captureInteractionState(from webView: WKWebView) {
            // `interactionState` is documented as an opaque value; hold it
            // as-is (no cast) and only ever hand it back to WebKit.
            state.saveInteractionState(webView.interactionState)
        }

        // MARK: - WKNavigationDelegate

        /// Marks the surface as loading when WebKit starts a provisional navigation.
        public func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            guard acceptsCallbacks(from: webView) else { return }
            state.navigationDidStart()
        }

        /// Records the destination only after WebKit explicitly commits it.
        public func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            guard acceptsCallbacks(from: webView) else { return }
            state.navigationDidCommit(url: webView.url)
        }

        /// Commits the final URL, title, and interaction state after a successful navigation.
        public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard acceptsCallbacks(from: webView) else { return }
            pageMetadataCoalescer.discardPending()
            state.navigationDidFinish(url: webView.url, title: webView.title)
            captureInteractionState(from: webView)
        }

        /// Presents a failure that occurred after WebKit committed the destination.
        public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
            guard acceptsCallbacks(from: webView) else { return }
            failNavigation(on: webView, with: error, wasProvisional: false)
        }

        /// Presents a failure that occurred before WebKit committed the destination.
        public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
            guard acceptsCallbacks(from: webView) else { return }
            failNavigation(on: webView, with: error, wasProvisional: true)
        }

        private func failNavigation(
            on webView: WKWebView,
            with error: any Error,
            wasProvisional: Bool
        ) {
            // A cancelled load reports `NSURLErrorCancelled`. This is not a
            // failure to surface; it happens on a user stop AND when a new
            // navigation replaces an in-flight one. Mirror the web view's real
            // `isLoading` rather than forcing `false`, so the chrome stays in the
            // loading state when a replacement navigation is still in flight.
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled {
                if webView.isLoading {
                    state.isLoading = true
                } else {
                    state.navigationDidCancel()
                }
                return
            }
            let failingValue = nsError.userInfo[NSURLErrorFailingURLErrorKey]
            let failedURL = failingValue as? URL
                ?? (failingValue as? String).flatMap(URL.init(string:))
                ?? webView.url
                ?? state.currentURL
            state.navigationDidFail(
                message: error.localizedDescription,
                url: failedURL,
                wasProvisional: wasProvisional
            )
        }

        /// Applies the surface's content-mode preference (mobile/desktop/
        /// recommended) to every navigation and allows it to proceed.
        public func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            preferences: WKWebpagePreferences,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy, WKWebpagePreferences) -> Void
        ) {
            guard acceptsCallbacks(from: webView) else {
                decisionHandler(.cancel, preferences)
                return
            }
            preferences.preferredContentMode = state.contentModePreference.webKitContentMode
            decisionHandler(.allow, preferences)
        }

        // MARK: - WKUIDelegate

        public func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            guard acceptsCallbacks(from: webView) else { return nil }
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

extension BrowserContentModePreference {
    /// The WebKit content mode this preference requests for page loads.
    var webKitContentMode: WKWebpagePreferences.ContentMode {
        switch self {
        case .recommended: .recommended
        case .mobile: .mobile
        case .desktop: .desktop
        }
    }
}
#endif
