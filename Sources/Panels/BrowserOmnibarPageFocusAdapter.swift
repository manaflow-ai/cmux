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
            // WebKit may invoke an Objective-C completion without an active
            // main-actor executor during nested menu tracking. Hop explicitly
            // so the repository can classify the raw result/error without
            // racing its main-actor state or touching AppKit off-actor.
            Task { @MainActor in
                completion(result, error)
            }
        }
    }
}
