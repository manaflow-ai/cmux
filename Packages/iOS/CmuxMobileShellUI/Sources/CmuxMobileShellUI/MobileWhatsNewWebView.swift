#if os(iOS)
import CmuxMobileSupport
import SwiftUI
import WebKit

/// Minimal in-app webview for What's New web pages, rendering a
/// ``MobileWhatsNewWebPageLoad``: cmux-owned hosts only, system-background
/// appearance so remote pages match the app, a quiet offline placeholder
/// with a retry control instead of an error shell, and a bounded load
/// deadline so a stalled page cannot stay blank forever.
///
/// The one-time launch sheet passes a load it already finished BEFORE
/// presenting (`preloadedLoad`), so the page renders the instant the sheet
/// appears. Without one (the Settings archive push, a retry), the view
/// creates its own load in place: the page renders as the signed-in app
/// user via the environment's `mobileWebAppSession` session exchange, or as
/// an anonymous visitor when no session is available. Try Again always
/// starts a fresh load with a fresh session exchange, which also recovers
/// an expired session. The webview follows the app's resolved light/dark
/// appearance and flips live when it changes.
struct MobileWhatsNewWebView: View {
    let url: URL
    let allowedHosts: Set<String>
    /// A load finished before this view was surfaced. The sheet path never
    /// shows loading UI because presentation already gated on this load's
    /// outcome.
    var preloadedLoad: MobileWhatsNewWebPageLoad?
    /// Deadline for an in-place load, including the session exchange; after
    /// it the quiet failure state with the retry control replaces the
    /// (possibly blank) webview.
    var loadDeadline: Duration = .seconds(20)
    @Environment(\.mobileWebAppSession) private var webAppSession
    @Environment(\.colorScheme) private var colorScheme
    @State private var attempt = 0
    @State private var localLoad: (attempt: Int, load: MobileWhatsNewWebPageLoad)?

    private var load: MobileWhatsNewWebPageLoad? {
        localLoad?.load ?? preloadedLoad
    }

    var body: some View {
        ZStack {
            PlatformPalette.systemBackground
                .ignoresSafeArea()
            if load?.phase == .failed {
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
            } else if let load {
                WhatsNewWebViewInstaller(webView: load.webView)
                    .id(ObjectIdentifier(load))
            }
        }
        .task(id: attempt) {
            startLoadIfNeeded()
        }
        .accessibilityIdentifier("MobileWhatsNewWebView")
    }

    /// Creates this attempt's in-place load. Attempt 0 defers to a preloaded
    /// page when one exists; re-appearances (sheet page swipes, navigation
    /// returns) keep the existing load and its webview instead of reloading
    /// the page.
    private func startLoadIfNeeded() {
        if attempt == 0, preloadedLoad != nil { return }
        guard localLoad?.attempt != attempt else { return }
        localLoad = (
            attempt: attempt,
            load: MobileWhatsNewWebPageLoad(
                url: url,
                allowedHosts: allowedHosts,
                webAppSession: webAppSession,
                deadline: loadDeadline,
                initialInterfaceStyle: colorScheme == .dark ? .dark : .light
            )
        )
    }
}

/// Installs an externally owned webview and keeps it pinned to the APP's
/// resolved appearance (the SwiftUI environment's color scheme, which
/// reflects the system setting plus any in-app override up the hierarchy)
/// instead of the raw device trait, so the page's `prefers-color-scheme`
/// and its dynamic system colors always match the surrounding chrome.
/// `updateUIView` reads the environment again on every SwiftUI update, so
/// an appearance change flips the live page immediately.
private struct WhatsNewWebViewInstaller: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView {
        applyResolvedAppearance(to: webView, context: context)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        applyResolvedAppearance(to: webView, context: context)
    }

    private func applyResolvedAppearance(to webView: WKWebView, context: Context) {
        webView.overrideUserInterfaceStyle =
            context.environment.colorScheme == .dark ? .dark : .light
    }
}
#endif
