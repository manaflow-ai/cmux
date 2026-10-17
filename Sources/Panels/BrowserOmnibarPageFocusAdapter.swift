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
        completion: @escaping @MainActor @Sendable (Any?, (any Error)?) -> Void
    ) {
        guard let panel else {
            completion(nil, nil)
            return
        }
        // A Chromium panel's page is its engine page; its WebKit view is unused.
        if let enginePage = panel.enginePage {
            Task { @MainActor in
                do {
                    completion(try await enginePage.evaluateJavaScript(script, in: .page), nil)
                } catch {
                    completion(nil, error)
                }
            }
            return
        }
        let bridge = BrowserJavaScriptCompletionBridge()
        panel.webView.evaluateJavaScript(script) { result, error in
            // WebKit may invoke an Objective-C completion without an active
            // main-actor executor during nested menu tracking. The bridge
            // preserves the raw result/error while hopping to the repository's
            // promised actor.
            bridge.deliver(result: result, error: error, to: completion)
        }
    }
}
