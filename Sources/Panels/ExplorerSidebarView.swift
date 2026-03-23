import SwiftUI
import WebKit

/// NSViewRepresentable that wraps the explorer sidebar's WKWebView.
struct ExplorerWebViewRepresentable: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> WKWebView {
        webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

/// SwiftUI view for the file explorer sidebar section.
struct ExplorerSidebarView: View {
    @ObservedObject var panel: ExplorerSidebarPanel

    var body: some View {
        ExplorerWebViewRepresentable(webView: panel.webView)
    }
}
