import AppKit
import WebKit

@MainActor
enum BrowserDeveloperToolsDockControlNormalizer {
    static func normalize(
        inspectorFrontendWebView: WKWebView?,
        hostWindow: NSWindow?,
        panel: BrowserPanel? = nil,
        allowSideDock: Bool = true
    ) {
        guard let inspectorFrontendWebView else { return }
        if let panel {
            BrowserDeveloperToolsDockRequestBridge.install(
                on: inspectorFrontendWebView,
                panel: panel
            )
        }
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
        BrowserDeveloperToolsDockControlNormalizer.normalize(
            inspectorFrontendWebView: webView.cmuxInspectorFrontendWebView(),
            hostWindow: webView.window,
            panel: self
        )
    }
}
