import CmuxBrowser
import Foundation
import WebKit

extension BrowserPanel {
    /// Whether the user pinned this pane's page to stay live while hidden.
    /// A pinned page is never discarded, even under system memory pressure.
    var keepsPageActiveWhileHidden: Bool {
        get { hiddenWebViewDiscardManager.keepsPageActive }
        set { hiddenWebViewDiscardManager.keepsPageActive = newValue }
    }

    /// The pin as the session file stores it: omitted when not pinned.
    var keepsPageActiveForSessionSnapshot: Bool? {
        keepsPageActiveWhileHidden ? true : nil
    }

    /// This pane as the memory budget sees it. A pane with no live WebContent
    /// process, because it was discarded or its process died, holds no memory.
    func hiddenMemoryBudgetPane(
        now: Date,
        processIdentifier: (WKWebView) -> Int?
    ) -> BrowserHiddenWebViewMemoryBudgetPlanner.Pane {
        let hasLiveProcess = !hiddenWebViewDiscardManager.isDiscardedForMemory
            && !hasRecoverableWebContentTermination
        return BrowserHiddenWebViewMemoryBudgetPlanner.Pane(
            id: id,
            processID: hasLiveProcess ? processIdentifier(webView) : nil,
            isVisible: isWebViewVisibleInUI,
            hiddenAt: webViewLastHiddenAt,
            isEvictable: hiddenWebViewDiscardManager.isEligibleForMemoryBudgetDiscard(now: now)
        )
    }

    /// Discards this hidden pane to bring hidden web content back under the
    /// memory budget, if nothing protects it.
    ///
    /// - Returns: Whether the pane was discarded.
    @discardableResult
    func discardHiddenWebViewForMemoryBudget(now: Date = Date()) -> Bool {
        hiddenWebViewDiscardManager.requestMemoryBudgetDiscard(now: now)
            && hiddenWebViewDiscardManager.isDiscardedForMemory
    }
}
