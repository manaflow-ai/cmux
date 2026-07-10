import AppKit
import WebKit

@MainActor
struct HostedInspectorAttachedSizeSync {
    static func sync(frontendWebView: WKWebView?, dockSide: HostedInspectorDockSide, extent: CGFloat) {
        guard let frontendWebView else {
#if DEBUG
            cmuxDebugLog("browser.inspector.attachedSizeSync skip=nilFrontend dock=\(dockSide) extent=\(String(format: "%.1f", extent))")
#endif
            return
        }
#if DEBUG
        let script = javaScript(dockSide: dockSide, extent: extent)
        frontendWebView.evaluateJavaScript(script) { result, error in
            cmuxDebugLog(
                "browser.inspector.attachedSizeSync dock=\(dockSide) extent=\(String(format: "%.1f", extent)) " +
                "result=\(String(describing: result)) error=\(error.map { String(describing: $0) } ?? "nil")"
            )
        }
#else
        frontendWebView.evaluateJavaScript(
            javaScript(dockSide: dockSide, extent: extent),
            completionHandler: nil
        )
#endif
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
