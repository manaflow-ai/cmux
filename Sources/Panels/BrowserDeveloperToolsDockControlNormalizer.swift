import AppKit
import WebKit

@MainActor
struct BrowserDeveloperToolsDockControlNormalizer {
    func normalize(
        inspectorFrontendWebView: WKWebView?,
        hostWindow: NSWindow?,
        panel: BrowserPanel? = nil,
        allowSideDock: Bool = true
    ) {
        guard let inspectorFrontendWebView else { return }
        if let panel {
            panel.installDeveloperToolsDockRequestBridge(
                on: inspectorFrontendWebView
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
        BrowserDeveloperToolsDockControlNormalizer().normalize(
            inspectorFrontendWebView: webView.cmuxInspectorFrontendWebView(),
            hostWindow: webView.window,
            panel: self
        )
    }
}
