import Foundation
import WebKit

/// Installs a debounced page-text extractor on a `WKWebView` so that
/// browser-panel contents flow into the global search index.
///
/// Designed as a tiny extension callable from `BrowserPanel` /
/// `CmuxWebView` once per webview, *after* the navigation delegate
/// is set. The hook captures `document.body.innerText` on
/// `webView:didFinish:` (with a 600 ms debounce against rapid SPA
/// navigation) and forwards the result to `SearchIndex.upsert(...)`
/// in a background task. No effect on rendering.
///
/// Wire-up (P3.5, one line in `BrowserPanel.makeWebView` or wherever
/// the webview is first handed back):
///
///     CmuxBrowserCaptureHook.install(
///         on: webView,
///         windowID: window.id,
///         workspaceID: workspace.id,
///         panelID: panel.id,
///         index: AppDelegate.shared?.searchIndex)
///
/// The hook holds itself alive via the webview's
/// `associatedObjects`; releasing the webview releases the hook.
@MainActor
public final class CmuxBrowserCaptureHook: NSObject, WKNavigationDelegate {
    private static var keyHolder: UInt8 = 0

    private weak var webView: WKWebView?
    private weak var forwardDelegate: WKNavigationDelegate?
    private let windowID: UUID
    private let workspaceID: UUID
    private let panelID: UUID
    private let index: SearchIndex?
    private var debounce: Task<Void, Never>?

    public static func install(
        on webView: WKWebView,
        windowID: UUID, workspaceID: UUID, panelID: UUID,
        index: SearchIndex?
    ) {
        let hook = CmuxBrowserCaptureHook(
            webView: webView,
            windowID: windowID, workspaceID: workspaceID,
            panelID: panelID, index: index)
        // Retain via objc associated object; chain the previous delegate.
        hook.forwardDelegate = webView.navigationDelegate
        webView.navigationDelegate = hook
        objc_setAssociatedObject(
            webView, &keyHolder, hook, .OBJC_ASSOCIATION_RETAIN)
    }

    private init(webView: WKWebView,
                 windowID: UUID, workspaceID: UUID, panelID: UUID,
                 index: SearchIndex?) {
        self.webView = webView
        self.windowID = windowID
        self.workspaceID = workspaceID
        self.panelID = panelID
        self.index = index
    }

    public func webView(_ wv: WKWebView, didFinish nav: WKNavigation!) {
        forwardDelegate?.webView?(wv, didFinish: nav)
        scheduleCapture()
    }

    public func webView(_ wv: WKWebView,
                        didFailProvisionalNavigation nav: WKNavigation!,
                        withError error: Error) {
        forwardDelegate?.webView?(wv, didFailProvisionalNavigation: nav, withError: error)
    }

    private func scheduleCapture() {
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled, let self else { return }
            await self.capture()
        }
    }

    private func capture() async {
        guard let webView, let index else { return }
        let urlString = webView.url?.absoluteString ?? ""
        let title = webView.title ?? ""
        let text: String = await withCheckedContinuation { cont in
            webView.evaluateJavaScript("document.body.innerText") { result, _ in
                cont.resume(returning: (result as? String) ?? "")
            }
        }
        let body = [title, urlString, text]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        guard !body.isEmpty else { return }
        await index.upsert(
            windowID: windowID, workspaceID: workspaceID,
            panelID: panelID, kind: .browser,
            anchor: urlString, text: String(body.prefix(100_000)))
    }
}
