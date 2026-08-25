#if os(iOS)
import CmuxMobileSupport
import SwiftUI
import WebKit

/// Whether a What's New webpage may load `url`: https on an allowlisted
/// cmux-owned host, or plain http only for a loopback development host that
/// is itself allowlisted (how local dev servers are addressed). One policy
/// covers the initial page and every subsequent navigation, so an https page
/// cannot downgrade to plaintext through a link or redirect.
func whatsNewWebURLAllowed(_ url: URL, allowedHosts: Set<String>) -> Bool {
    guard let host = url.host?.lowercased(), allowedHosts.contains(host) else { return false }
    switch url.scheme?.lowercased() {
    case "https":
        return true
    case "http":
        return host == "localhost" || host == "127.0.0.1"
    default:
        return false
    }
}

/// Minimal in-app webview for What's New web pages: cmux-owned hosts only,
/// system-background appearance so remote pages match the app, a quiet
/// offline placeholder with a retry control instead of an error shell, and a
/// bounded load deadline so a stalled page cannot stay blank forever.
/// Navigation away from the allowlisted hosts is cancelled.
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
    /// Deadline for the initial page load; after it the quiet failure state
    /// with the retry control replaces the (possibly blank) webview.
    var loadDeadline: Duration = .seconds(20)
    @State private var phase: LoadPhase = .loading
    @State private var attempt = 0

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
            } else {
                WhatsNewWebViewRepresentable(
                    url: url,
                    allowedHosts: allowedHosts,
                    onFinish: { phase = .loaded },
                    onFailure: { phase = .failed }
                )
                .id(attempt)
                .task(id: attempt) {
                    // Bounded deadline for the initial load; cancelled with
                    // the view (and superseded by a retry) via task identity.
                    guard (try? await ContinuousClock().sleep(for: loadDeadline)) != nil else { return }
                    if phase == .loading { phase = .failed }
                }
            }
        }
        .accessibilityIdentifier("MobileWhatsNewWebView")
    }
}

private struct WhatsNewWebViewRepresentable: UIViewRepresentable {
    let url: URL
    let allowedHosts: Set<String>
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
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        private let allowedHosts: Set<String>
        private let onFinish: @MainActor () -> Void
        private let onFailure: @MainActor () -> Void

        init(
            allowedHosts: Set<String>,
            onFinish: @escaping @MainActor () -> Void,
            onFailure: @escaping @MainActor () -> Void
        ) {
            self.allowedHosts = allowedHosts
            self.onFinish = onFinish
            self.onFailure = onFailure
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction
        ) async -> WKNavigationActionPolicy {
            guard let url = navigationAction.request.url,
                  whatsNewWebURLAllowed(url, allowedHosts: allowedHosts) else {
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
