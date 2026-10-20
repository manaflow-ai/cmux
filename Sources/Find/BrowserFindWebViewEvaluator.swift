import CmuxBrowser
import WebKit

/// Evaluates find-in-page scripts against the current `WKWebView` of a `BrowserPanel`.
///
/// `BrowserPanel` owns its `BrowserFindService`, which owns this adapter, which holds a `weak`
/// reference back to the panel. The weak back-reference breaks what would otherwise be a retain
/// cycle (panel → service → evaluator → panel) and lets each evaluation read the panel's current
/// `webView`, which is reassigned on profile switches.
@MainActor
final class BrowserFindWebViewEvaluator: BrowserFindScriptEvaluating {
    private weak var panel: BrowserPanel?

    /// Creates an evaluator bound to a panel.
    /// - Parameter panel: The panel whose live `webView` find scripts run against.
    init(panel: BrowserPanel) {
        self.panel = panel
    }

    func evaluate(_ script: BrowserFindScript) async throws -> Any? {
        guard let panel else { return nil }
        return try await panel.webView.evaluateJavaScript(script.source)
    }
}
