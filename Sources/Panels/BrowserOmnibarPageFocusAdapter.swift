import CmuxBrowser
import WebKit

/// Bridges the omnibar page-focus repository to a panel's live web view.
///
/// The panel is held weakly so the repository and adapter do not form a retain
/// cycle. The current web view is read at evaluation time because a panel can
/// replace it during navigation or profile changes.
@MainActor
final class BrowserOmnibarPageFocusAdapter: BrowserOmnibarScriptEvaluating {
    private weak var panel: BrowserPanel?

    init(panel: BrowserPanel) {
        self.panel = panel
    }

    func evaluateOmnibarPageFocusScript(
        _ script: String,
        completion: @escaping @MainActor (Any?, (any Error)?) -> Void
    ) {
        guard let panel else {
            completion(nil, nil)
            return
        }
        panel.webView.evaluateJavaScript(script) { result, error in
            // WebKit's completion is UI-actor isolated. Deliver its raw result
            // and error directly so nested menu tracking cannot trip a runtime
            // `MainActor.assumeIsolated` assertion before the repository can
            // classify the outcome.
            completion(result, error)
        }
    }
}
