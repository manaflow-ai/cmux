import SwiftUI
import WebKit

private struct NativeWebView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView()
        context.coordinator.lastURL = url
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        guard context.coordinator.lastURL != url else { return }
        context.coordinator.lastURL = url
        webView.load(URLRequest(url: url))
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var lastURL: URL?
    }
}

struct BrowserSurfaceView: View {
    let browser: BrowserSnapshot

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "lock.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(browser.url)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                Spacer()
                if browser.loading {
                    ProgressView().controlSize(.mini)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(.bar)
            Divider()
            if let url = URL(string: browser.url) {
                NativeWebView(url: url)
            } else {
                ContentUnavailableView(
                    L10n.text("browser.invalid_url", "This browser tab has no valid URL."),
                    systemImage: "exclamationmark.triangle"
                )
            }
        }
    }
}
