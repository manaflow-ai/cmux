#if os(iOS) && canImport(WebKit)
import CmuxMobileShellModel
import SwiftUI
@preconcurrency import UIKit
@preconcurrency import WebKit

/// SwiftUI host for the read-only diff-viewer `WKWebView`.
///
/// Builds one `WKWebView` whose `cmux-diff://` scheme is served by a
/// ``DiffViewerSchemeHandler`` bound to a specific patch, then loads the host
/// page. The web view is configured for read-only review: no zoom-disabling, but
/// no editing affordances are exposed by the bundle, and the custom scheme keeps
/// the page off the network entirely.
///
/// The representable is intentionally stateless about reloads: the diff content
/// is fixed at make time, so when the patch changes the SwiftUI parent rebuilds
/// the whole representable via `.id(...)`. This avoids re-fetching or mutating
/// the live web view (matching the no-`updateUIView`-work convention used by the
/// terminal surface representable).
struct DiffViewerWebView: UIViewRepresentable {
    let diff: MobileWorkspaceDiff
    let title: String
    let prefersDark: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        let handler = DiffViewerSchemeHandler(
            html: DiffViewerHostHTML.page(
                title: title,
                sourceLabel: diff.sourceLabel,
                prefersDark: prefersDark
            ),
            patch: diff.patch
        )
        // Retain the handler for the web view's lifetime; WebKit holds it weakly.
        context.coordinator.handler = handler
        configuration.setURLSchemeHandler(handler, forURLScheme: diffViewerScheme)

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        // Read-only review: the bundle never exposes editing, but also disable
        // long-press link/data-detector interactions that would offer share/copy
        // sheets unrelated to reviewing the diff.
        #if !targetEnvironment(macCatalyst)
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        #endif

        let origin = URL(string: "\(diffViewerScheme)://\(diffViewerHost)/")!
        webView.load(URLRequest(url: origin))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        // No-op: content is fixed at make time and the parent rebuilds via `.id`.
    }

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        uiView.stopLoading()
        coordinator.handler = nil
    }

    @MainActor
    final class Coordinator {
        var handler: DiffViewerSchemeHandler?
    }
}
#endif
