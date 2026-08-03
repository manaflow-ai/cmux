#if canImport(UIKit)
import Observation
public import UIKit
public import WebKit

/// UIKit owner for a single `WKWebView` bound to a ``BrowserSurfaceState``.
/// Observation drives pending navigation work directly, so mounting does not
/// depend on a declarative rendering pass.
@MainActor
public final class MobileBrowserView: UIView {
    public let webView: WKWebView
    private let state: BrowserSurfaceState
    private let coordinator: Coordinator

    public init(state: BrowserSurfaceState) {
        self.state = state
        webView = Self.makeConfiguredWebView()
        coordinator = Coordinator(state: state)
        super.init(frame: .zero)
        backgroundColor = .systemBackground
        webView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        coordinator.attach(webView: webView)
        observePendingWork()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Builds a browser web view with cmux's fixed mobile navigation policy.
    public static func makeConfiguredWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.allowsInlineMediaPlayback = true
        let webView = WKWebView(frame: .zero, configuration: configuration)
        // The enclosing workspace navigation controller owns the edge swipe.
        webView.allowsBackForwardNavigationGestures = false
        return webView
    }

    private func observePendingWork() {
        withObservationTracking {
            _ = state.loadRequest
            _ = state.pendingCommand
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.coordinator.applyPendingWork()
                self.observePendingWork()
            }
        }
        coordinator.applyPendingWork()
    }

    /// Owns navigation delegates and mirrors WebKit state into the observable
    /// browser model.
    @MainActor
    public final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        private let state: BrowserSurfaceState
        private weak var webView: WKWebView?
        private var observations: [NSKeyValueObservation] = []

        public init(state: BrowserSurfaceState) {
            self.state = state
            super.init()
        }

        func attach(webView: WKWebView) {
            detach()
            self.webView = webView
            webView.navigationDelegate = self
            webView.uiDelegate = self
            observe(webView)
            let hadPendingLoad = state.loadRequest != nil
            applyPendingWork()
            if !hadPendingLoad, webView.url == nil, let restore = state.currentURL {
                webView.load(URLRequest(url: restore))
            }
        }

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

        func detach() {
            observations.forEach { $0.invalidate() }
            observations.removeAll()
            webView?.navigationDelegate = nil
            webView?.uiDelegate = nil
            webView = nil
        }

        private func observe(_ webView: WKWebView) {
            observations = [
                webView.observe(\.estimatedProgress) { [state] webView, _ in
                    MainActor.assumeIsolated { state.estimatedProgress = webView.estimatedProgress }
                },
                webView.observe(\.title) { [state] webView, _ in
                    MainActor.assumeIsolated {
                        if let title = webView.title, !title.isEmpty { state.title = title }
                    }
                },
                webView.observe(\.url) { [state] webView, _ in
                    MainActor.assumeIsolated {
                        state.currentURL = webView.url
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

        public func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            state.navigationDidStart()
        }

        public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            state.navigationDidFinish()
            if let title = webView.title, !title.isEmpty { state.title = title }
        }

        public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
            failNavigation(with: error)
        }

        public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
            failNavigation(with: error)
        }

        private func failNavigation(with error: any Error) {
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled {
                state.isLoading = webView?.isLoading ?? false
                if !state.isLoading { state.estimatedProgress = 0 }
                return
            }
            state.navigationDidFail(message: error.localizedDescription)
        }

        public func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if navigationAction.targetFrame == nil {
                webView.load(navigationAction.request)
            }
            return nil
        }
    }
}
#endif
