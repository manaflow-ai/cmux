#if os(iOS)
import CmuxMobileSupport
import SwiftUI
import WebKit

/// One What's New web page load lifecycle, owned outside the presented view
/// hierarchy so a page can finish loading BEFORE any surface that shows it
/// appears (HIG Loading: the best content-loading experience finishes before
/// people become aware of it). Owns the webview, the web-session exchange,
/// the cookie seeding, the navigation allowlist, and a bounded deadline.
///
/// The load settles into a terminal phase exactly once: `loaded` when the
/// initial page finished, `failed` on the first load error or when the
/// deadline passes. Later navigation failures (an off-allowlist tap the
/// policy cancelled, a dead link) never tear down the already-rendered page,
/// and the allowlist keeps applying to every navigation for the webview's
/// whole lifetime.
@MainActor
@Observable
final class MobileWhatsNewWebPageLoad {
    enum Phase {
        case loading
        case loaded
        case failed
    }

    let url: URL
    let webView: WKWebView
    private(set) var phase: Phase = .loading

    private let navigator: Navigator
    private var loadTask: Task<Void, Never>?
    private var deadlineTask: Task<Void, Never>?
    private var outcomeContinuations: [CheckedContinuation<Phase, Never>] = []

    /// Creates the webview and immediately starts the load: exchange the
    /// native session for web session cookies (`nil` session renders the
    /// page as an anonymous visitor rather than blocking release-note
    /// content behind auth), seed them into the webview's own non-persistent
    /// data store, then load the page. `deadline` bounds the whole sequence;
    /// `initialInterfaceStyle` pins the off-window load to the app's
    /// resolved appearance so the page does not flash the other scheme when
    /// it is installed into the hierarchy.
    init(
        url: URL,
        allowedHosts: Set<String>,
        webAppSession: (any MobileWebAppSessionProviding)?,
        deadline: Duration,
        initialInterfaceStyle: UIUserInterfaceStyle = .unspecified,
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.url = url
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = .systemBackground
        webView.scrollView.backgroundColor = .systemBackground
        webView.allowsBackForwardNavigationGestures = false
        webView.overrideUserInterfaceStyle = initialInterfaceStyle
        self.webView = webView
        navigator = Navigator(allowedHosts: allowedHosts)
        navigator.owner = self
        webView.navigationDelegate = navigator

        loadTask = Task { [weak self, url] in
            let cookies = await Self.exchangeSessionCookies(webAppSession, for: url)
            guard let self, !Task.isCancelled else { return }
            let store = self.webView.configuration.websiteDataStore.httpCookieStore
            for cookie in cookies {
                guard !Task.isCancelled else { return }
                await store.setCookie(cookie)
            }
            guard !Task.isCancelled else { return }
            self.webView.load(URLRequest(url: url))
        }
        // Intentional bounded timeout through an injected Clock, cancelled by
        // `settle(_:)` the moment the load reaches a terminal phase.
        deadlineTask = Task { [weak self] in
            guard (try? await clock.sleep(for: deadline)) != nil else { return }
            self?.settle(.failed)
        }
    }

    /// Runs the network-bound session exchange off the main actor so page
    /// preloads never occupy it; the webview and cookie-store mutations stay
    /// main-actor in the calling task.
    @concurrent
    private nonisolated static func exchangeSessionCookies(
        _ session: (any MobileWebAppSessionProviding)?,
        for url: URL
    ) async -> [HTTPCookie] {
        await session?.sessionCookies(for: url) ?? []
    }

    // No deinit cancellation: both tasks hold `self` weakly and settle or
    // exit within the bounded deadline on their own, and `settle(_:)`
    // cancels them on every terminal path. A nonisolated deinit cannot
    // touch these main-actor properties anyway.

    /// Suspends until the load settles. Always resumes: the deadline task
    /// guarantees a terminal phase even when the network stalls, so a caller
    /// gating presentation on this can never hang.
    func outcome() async -> Phase {
        if phase != .loading { return phase }
        return await withCheckedContinuation { outcomeContinuations.append($0) }
    }

    private func settle(_ terminal: Phase) {
        guard phase == .loading else { return }
        phase = terminal
        deadlineTask?.cancel()
        deadlineTask = nil
        if terminal == .failed {
            loadTask?.cancel()
            loadTask = nil
            webView.stopLoading()
        }
        let continuations = outcomeContinuations
        outcomeContinuations = []
        for continuation in continuations {
            continuation.resume(returning: terminal)
        }
    }

    @MainActor
    private final class Navigator: NSObject, WKNavigationDelegate {
        private let allowedHosts: Set<String>
        weak var owner: MobileWhatsNewWebPageLoad?

        init(allowedHosts: Set<String>) {
            self.allowedHosts = allowedHosts
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction
        ) async -> WKNavigationActionPolicy {
            guard let url = navigationAction.request.url,
                  mobileWebPageURLAllowed(url, allowedHosts: allowedHosts) else {
                // WebKit-internal blank navigations carry no host; cancelling
                // one would fail a load that never touched the network.
                if navigationAction.request.url?.absoluteString == "about:blank" {
                    return .allow
                }
                // A rejected MAIN-FRAME navigation ends the page load (a
                // redirect to an off-allowlist host mid-load, for example),
                // so settle immediately instead of depending on WebKit to
                // report the policy cancellation before the deadline. After
                // settling this is a no-op, preserving the rendered page on
                // off-allowlist link taps.
                if navigationAction.targetFrame?.isMainFrame != false {
                    owner?.settle(.failed)
                }
                return .cancel
            }
            return .allow
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            owner?.settle(.loaded)
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            owner?.settle(.failed)
        }

        func webView(
            _ webView: WKWebView,
            didFail navigation: WKNavigation!,
            withError error: Error
        ) {
            owner?.settle(.failed)
        }
    }
}
#endif
