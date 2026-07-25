public import SwiftUI
public import WebKit

/// Hosts a web-backed custom sidebar.
///
/// Deliberately chrome-less: no omnibar, no tab bar, no navigation controls. The page *is* the
/// sidebar, so any chrome above it is taken directly out of the sidebar's usable height — which is
/// the reason to host on the left at all rather than opening a browser pane in the Dock.
public struct CustomSidebarWebView: NSViewRepresentable {
    private let source: CustomSidebarWebSource

    public init(source: CustomSidebarWebSource) {
        self.source = source
    }

    public func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        // The page paints its own background. Letting the web view draw one flashes white on every
        // load, which is jarring against the sidebar's chrome in dark mode.
        webView.setValue(false, forKey: "drawsBackground")
        // A sidebar is not a browser: swiping should not navigate away from the page, leaving the
        // user on a blank view with no visible way back.
        webView.allowsBackForwardNavigationGestures = false
        context.coordinator.load(source, into: webView)
        return webView
    }

    public func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.load(source, into: webView)
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    /// MainActor-isolated because every `WKWebView` mutation it performs is, and the
    /// representable's make/update callbacks already run there.
    @MainActor
    public final class Coordinator {
        private var loadedSource: CustomSidebarWebSource?

        /// Loads only when the source actually changed.
        ///
        /// `updateNSView` runs on unrelated SwiftUI invalidations — and the custom sidebar is
        /// mounted inside a one-second `TimelineView` — so reloading unconditionally would discard
        /// the page's scroll position, filter text, and open menus roughly once a second.
        func load(_ source: CustomSidebarWebSource, into webView: WKWebView) {
            guard loadedSource != source else { return }
            loadedSource = source
            switch source {
            case let .document(fileURL):
                // Read access is scoped to the document's own directory so a sidebar can pull in
                // sibling assets without being handed the rest of the filesystem.
                webView.loadFileURL(fileURL, allowingReadAccessTo: fileURL.deletingLastPathComponent())
            case let .remote(url):
                webView.load(URLRequest(url: url))
            }
        }
    }
}
