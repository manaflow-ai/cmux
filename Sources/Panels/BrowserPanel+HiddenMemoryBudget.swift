import CmuxBrowser
import Foundation
import WebKit

extension BrowserPanel {
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
