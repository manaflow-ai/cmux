import CmuxBrowser
import WebKit

/// Evaluates find-in-page scripts against the live `WKWebView` of a
/// `MarkdownPanel`'s preview renderer.
///
/// Mirrors `BrowserFindWebViewEvaluator`: the panel owns its
/// `BrowserFindService`, which owns this adapter, which holds a `weak`
/// reference back to the panel so the panel → service → evaluator → panel
/// chain never retains. Each evaluation reads the renderer session's current
/// web view, which is created lazily and survives split/tab layout churn.
@MainActor
final class MarkdownFindWebViewEvaluator: BrowserFindScriptEvaluating {
    private weak var panel: MarkdownPanel?

    /// Creates an evaluator bound to a markdown panel.
    /// - Parameter panel: The panel whose preview web view find scripts run against.
    init(panel: MarkdownPanel) {
        self.panel = panel
    }

    func evaluate(_ script: BrowserFindScript) async throws -> Any? {
        guard let webView = panel?.rendererSession.findScriptWebView else { return nil }
        return try await webView.evaluateJavaScript(script.source)
    }
}
