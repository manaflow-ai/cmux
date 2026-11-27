import CmuxNextDesign
import CmuxNextPages

/// Plumbing to the page-side half of the cmux NEXT own-window picker, which the
/// page installs itself; the native controller owns the screenshot, redaction
/// boundary and composer delivery.
extension AgentPaneView {
    /// Installs or removes the debug picker in this pane's document.
    public func setUiPointerInspector(_ enabled: Bool) {
        page?.evaluate(enabled ? Self.uiPointerScript : Self.uiPointerStopScript)
        if page == nil { webView.evaluateJavaScript(enabled ? Self.uiPointerScript : Self.uiPointerStopScript, completionHandler: nil) }
    }

    /// Runs a picker operation in whichever engine currently draws this pane.
    public func evaluateUiPointer(_ script: String) {
        if let page { page.evaluate(script) } else { webView.evaluateJavaScript(script, completionHandler: nil) }
    }

    /// View points per CSS pixel for the page currently drawing this pane.
    public var uiPointerPageZoom: Double {
        guard let page else { return webView.pageZoom * webView.magnification }
        return page.showsChromium
            ? Double(DesignSettings.shared.uiScale) * page.additionalZoom
            : page.webKitView.pageZoom * page.webKitView.magnification
    }

    // The picker itself is the page's own (webviews acpmux/uiPointer/picker.ts, installed at mount):
    // the page records the right-clicked element for Inspect Element before the native menu opens.
    private static let uiPointerStopScript = "globalThis.__cmuxUiPointer?.stop?.();"
    private static let uiPointerScript = "globalThis.__cmuxUiPointer?.start?.();"
}
