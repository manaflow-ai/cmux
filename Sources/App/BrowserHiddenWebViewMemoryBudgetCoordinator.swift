import CmuxBrowser
import Darwin
import Foundation
import WebKit

/// Keeps the memory held by hidden browser panes under the configured budget
/// by discarding the pane hidden longest first, like a Chrome tab discard
/// (https://github.com/manaflow-ai/cmux/issues/15069). Runs on each memory
/// monitor sample; the timer policy stays opt-in.
@MainActor
final class BrowserHiddenWebViewMemoryBudgetCoordinator {
    private let policyDefaults: UserDefaults
    private let browserPanels: @MainActor () -> [BrowserPanel]
    private let processIdentifier: @MainActor (WKWebView) -> Int?
    private let footprintBytes: (Int) -> UInt64?

    init(
        policyDefaults: UserDefaults = .standard,
        processIdentifier: @escaping @MainActor (WKWebView) -> Int? = { CmuxWebContentProcessIdentifier.pid(for: $0) },
        footprintBytes: @escaping (Int) -> UInt64? = { CmuxTopProcessSnapshot.resourceUsage(for: $0)?.ri_phys_footprint },
        browserPanels: @escaping @MainActor () -> [BrowserPanel]
    ) {
        self.policyDefaults = policyDefaults
        self.processIdentifier = processIdentifier
        self.footprintBytes = footprintBytes
        self.browserPanels = browserPanels
    }

    /// Discards hidden panes, hidden longest first, until the memory their
    /// web content holds fits the budget.
    ///
    /// - Returns: The number of panes discarded.
    @discardableResult
    func enforceBudget(now: Date = Date()) -> Int {
        let policy = BrowserHiddenWebViewDiscardPolicy.self
        guard policy.isEnabled(defaults: policyDefaults),
              policy.mode(defaults: policyDefaults) == .memoryBudget else { return 0 }

        let panels = browserPanels()
        // Each sample runs on the main actor; with every pane on screen there
        // is nothing to plan, so skip the per-pane checks and process reads.
        guard panels.contains(where: { !$0.isWebViewVisibleInUI }) else { return 0 }
        let panes = panels.map { $0.hiddenMemoryBudgetPane(now: now, processIdentifier: processIdentifier) }
        let planner = BrowserHiddenWebViewMemoryBudgetPlanner(budgetMB: policy.memoryBudgetMB(defaults: policyDefaults))
        let plan = planner.plan(panes: panes, footprintBytes: footprintBytes)
        guard !plan.panesToDiscard.isEmpty else { return 0 }

        let panelsByID = Dictionary(panels.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let discardedCount = plan.panesToDiscard.reduce(0) { count, paneID in
            let discarded = panelsByID[paneID]?.discardHiddenWebViewForMemoryBudget(now: now) == true
            return count + (discarded ? 1 : 0)
        }
#if DEBUG
        cmuxDebugLog(
            "browser.discard.budget budgetBytes=\(planner.budgetBytes) " +
            "hiddenBytes=\(plan.hiddenFootprintBytes) " +
            "remainingBytes=\(plan.remainingHiddenFootprintBytes) " +
            "planned=\(plan.panesToDiscard.count) discarded=\(discardedCount)"
        )
#endif
        return discardedCount
    }
}
