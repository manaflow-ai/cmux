import AppKit
import WebKit

@MainActor
struct BrowserDeveloperToolsDockControlNormalizer {
    func normalize(
        inspectorFrontendWebView: WKWebView?,
        hostWindow: NSWindow?,
        allowSideDock: Bool = true
    ) {
        guard let inspectorFrontendWebView else { return }
        let detachedFromHostWindow =
            inspectorFrontendWebView.window != nil &&
            inspectorFrontendWebView.window !== hostWindow
        inspectorFrontendWebView.evaluateJavaScript(
            HostedInspectorDockControlScript(
                allowSideDock: allowSideDock,
                detachedFromHostWindow: detachedFromHostWindow
            ).source,
            completionHandler: nil
        )
    }
}

extension BrowserPanel {
    func normalizeDeveloperToolsDockControls() {
        BrowserDeveloperToolsDockControlNormalizer().normalize(
            inspectorFrontendWebView: webView.cmuxInspectorFrontendWebView(),
            hostWindow: webView.window
        )
    }
}
