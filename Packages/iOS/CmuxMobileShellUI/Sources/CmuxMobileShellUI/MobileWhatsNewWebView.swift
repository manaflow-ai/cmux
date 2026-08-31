#if os(iOS)
import CmuxMobileSupport
import SwiftUI
import WebKit

/// Minimal in-app webview for What's New web pages: cmux-owned hosts only,
/// system-background appearance so remote pages match the app, a quiet
/// offline placeholder with a retry control instead of an error shell, and a
/// bounded load deadline so a stalled page cannot stay blank forever.
/// Navigation away from the allowlisted hosts is cancelled.
///
/// Pages render as the signed-in app user: before the first request, the
/// environment's `mobileWebAppSession` exchanges the native Stack session
/// for web session cookies, which are seeded into the webview's own
/// non-persistent data store (so the web session dies with this view). When
/// no session is available the page loads as an anonymous visitor, and Try
/// Again repeats the exchange with fresh tokens, which also recovers an
/// expired session. The webview follows the app's resolved light/dark
/// appearance and flips live when it changes.
struct MobileWhatsNewWebView: View {
    /// One webview load lifecycle: loading until the page finishes, then
    /// loaded; failed on error or when the load deadline passes first.
    private enum LoadPhase: Equatable {
        case loading
        case loaded
        case failed
    }

    let url: URL
    let allowedHosts: Set<String>
    /// Deadline for the initial page load, including the session exchange;
    /// after it the quiet failure state with the retry control replaces the
    /// (possibly blank) webview.
    var loadDeadline: Duration = .seconds(20)
    @Environment(\.mobileWebAppSession) private var webAppSession
    @State private var phase: LoadPhase = .loading
    @State private var attempt = 0
    /// The attempt whose session cookies are resolved; the webview mounts
    /// only once its own attempt resolved, so a retry always exchanges
    /// fresh tokens instead of reusing a stale session.
    @State private var resolvedAttempt: Int?
    @State private var sessionCookies: [HTTPCookie] = []

    var body: some View {
        ZStack {
            PlatformPalette.systemBackground
                .ignoresSafeArea()
            if phase == .failed {
                VStack(spacing: 12) {
                    Image(systemName: "wifi.slash")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text(L10n.string(
                        "mobile.whatsNew.webUnavailable",
                        defaultValue: "This page needs an internet connection."
                    ))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    Button {
                        phase = .loading
                        attempt += 1
                    } label: {
                        Text(L10n.string(
                            "mobile.whatsNew.webRetry",
                            defaultValue: "Try Again"
                        ))
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("MobileWhatsNewWebRetry")
                }
                .padding(32)
                .accessibilityIdentifier("MobileWhatsNewWebUnavailable")
            } else if resolvedAttempt == attempt {
                WhatsNewWebViewRepresentable(
                    url: url,
                    allowedHosts: allowedHosts,
                    sessionCookies: sessionCookies,
                    onFinish: { phase = .loaded },
                    // Only the initial load can fail into the placeholder.
                    // A later navigation failure (an off-allowlist tap the
                    // policy cancelled, a dead link) must not tear down the
                    // already-rendered page.
                    onFailure: { if phase == .loading { phase = .failed } }
                )
                .id(attempt)
            }
        }
        .task(id: attempt) {
            await resolveSession()
        }
        .task(id: attempt) {
            // Bounded deadline for the initial load (session exchange plus
            // page load); cancelled with the view (and superseded by a
            // retry) via task identity.
            guard (try? await ContinuousClock().sleep(for: loadDeadline)) != nil else { return }
            if phase == .loading { phase = .failed }
        }
        .accessibilityIdentifier("MobileWhatsNewWebView")
    }

    /// Exchanges the native session for this attempt's web session cookies.
    /// `nil` (signed out, exchange unavailable) renders the page without a
    /// session rather than blocking release-note content behind auth.
    private func resolveSession() async {
        guard resolvedAttempt != attempt else { return }
        let cookies = await webAppSession?.sessionCookies(for: url)
        guard !Task.isCancelled else { return }
        sessionCookies = cookies ?? []
        resolvedAttempt = attempt
    }
}

private struct WhatsNewWebViewRepresentable: UIViewRepresentable {
    let url: URL
    let allowedHosts: Set<String>
    let sessionCookies: [HTTPCookie]
    let onFinish: @MainActor () -> Void
    let onFailure: @MainActor () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(allowedHosts: allowedHosts, onFinish: onFinish, onFailure: onFailure)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = .systemBackground
        webView.scrollView.backgroundColor = .systemBackground
        webView.allowsBackForwardNavigationGestures = false
        applyResolvedAppearance(to: webView, context: context)
        context.coordinator.seedSessionAndLoad(
            webView,
            cookies: sessionCookies,
            url: url
        )
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        applyResolvedAppearance(to: webView, context: context)
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.cancelPendingLoad()
    }

    /// Pins the webview to the APP's resolved appearance (the SwiftUI
    /// environment's color scheme, which reflects the system setting plus
    /// any in-app override up the hierarchy) instead of the raw device
    /// trait, so the page's `prefers-color-scheme` and its dynamic system
    /// colors always match the surrounding chrome. `updateUIView` reads the
    /// environment again on every SwiftUI update, so an appearance change
    /// flips the live page immediately.
    private func applyResolvedAppearance(to webView: WKWebView, context: Context) {
        webView.overrideUserInterfaceStyle =
            context.environment.colorScheme == .dark ? .dark : .light
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        private let allowedHosts: Set<String>
        private let onFinish: @MainActor () -> Void
        private let onFailure: @MainActor () -> Void
        private var pendingLoad: Task<Void, Never>?

        init(
            allowedHosts: Set<String>,
            onFinish: @escaping @MainActor () -> Void,
            onFailure: @escaping @MainActor () -> Void
        ) {
            self.allowedHosts = allowedHosts
            self.onFinish = onFinish
            self.onFailure = onFailure
        }

        /// Seeds the session cookies into the webview's own data store
        /// before the first request (or the page would render signed out),
        /// then starts the load. Event-ordered on the cookie-store
        /// callbacks, and cancelled when the webview is dismantled.
        func seedSessionAndLoad(
            _ webView: WKWebView,
            cookies: [HTTPCookie],
            url: URL
        ) {
            pendingLoad = Task { @MainActor [weak webView] in
                for cookie in cookies {
                    guard !Task.isCancelled,
                          let store = webView?.configuration.websiteDataStore.httpCookieStore else {
                        return
                    }
                    await store.setCookie(cookie)
                }
                guard !Task.isCancelled, let webView else { return }
                webView.load(URLRequest(url: url))
            }
        }

        func cancelPendingLoad() {
            pendingLoad?.cancel()
            pendingLoad = nil
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction
        ) async -> WKNavigationActionPolicy {
            guard let url = navigationAction.request.url,
                  mobileWebPageURLAllowed(url, allowedHosts: allowedHosts) else {
                return .cancel
            }
            return .allow
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            onFinish()
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            onFailure()
        }

        func webView(
            _ webView: WKWebView,
            didFail navigation: WKNavigation!,
            withError error: Error
        ) {
            onFailure()
        }
    }
}
#endif
