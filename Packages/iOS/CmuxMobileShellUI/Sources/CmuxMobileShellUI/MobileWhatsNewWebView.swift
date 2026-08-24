#if os(iOS)
import CmuxMobileSupport
import SwiftUI
import WebKit

/// Minimal in-app webview for What's New web pages: cmux-owned hosts only,
/// system-background appearance so remote pages match the app, and a quiet
/// offline placeholder instead of an error shell. Navigation away from the
/// allowlisted hosts is cancelled.
struct MobileWhatsNewWebView: View {
    let url: URL
    let allowedHosts: Set<String>
    @State private var failedToLoad = false

    var body: some View {
        ZStack {
            PlatformPalette.systemBackground
                .ignoresSafeArea()
            if failedToLoad {
                VStack(spacing: 8) {
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
                }
                .padding(32)
                .accessibilityIdentifier("MobileWhatsNewWebUnavailable")
            } else {
                WhatsNewWebViewRepresentable(
                    url: url,
                    allowedHosts: allowedHosts,
                    onFailure: { failedToLoad = true }
                )
            }
        }
        .accessibilityIdentifier("MobileWhatsNewWebView")
    }
}

private struct WhatsNewWebViewRepresentable: UIViewRepresentable {
    let url: URL
    let allowedHosts: Set<String>
    let onFailure: @MainActor () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(allowedHosts: allowedHosts, onFailure: onFailure)
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
        private let onFailure: @MainActor () -> Void

        init(allowedHosts: Set<String>, onFailure: @escaping @MainActor () -> Void) {
            self.allowedHosts = allowedHosts
            self.onFailure = onFailure
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction
        ) async -> WKNavigationActionPolicy {
            guard let host = navigationAction.request.url?.host?.lowercased(),
                  allowedHosts.contains(host) else {
                return .cancel
            }
            return .allow
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
