import AppKit
import WebKit

@MainActor
struct HostedInspectorAttachedSizeSync {
    static func sync(frontendWebView: WKWebView?, dockSide: HostedInspectorDockSide, extent: CGFloat) {
        guard let frontendWebView else { return }
        frontendWebView.evaluateJavaScript(
            javaScript(dockSide: dockSide, extent: extent),
            completionHandler: nil
        )
    }

    static func sync(pageWebView: WKWebView?, dockSide: HostedInspectorDockSide, extent: CGFloat) {
        sync(
            frontendWebView: pageWebView?.cmuxInspectorFrontendWebView(),
            dockSide: dockSide,
            extent: extent
        )
    }

    nonisolated static func javaScript(dockSide: HostedInspectorDockSide, extent: CGFloat) -> String {
        let method = dockSide.isHorizontalDivider ? "setAttachedWindowHeight" : "setAttachedWindowWidth"
        let roundedExtent = max(0, Int(extent.rounded()))
        return """
        (() => {
            if (typeof InspectorFrontendHost === "undefined") { return false; }
            if (typeof InspectorFrontendHost.\(method) !== "function") { return false; }
            InspectorFrontendHost.\(method)(\(roundedExtent));
            return true;
        })();
        """
    }
}
