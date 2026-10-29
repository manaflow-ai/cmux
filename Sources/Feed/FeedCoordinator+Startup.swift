import Foundation
import CMUXAgentLaunch

// Feed reconciliation after restore and persistence draining on quit.
extension FeedCoordinator {
    /// Reconciles pending rows after asynchronous persistence startup. The
    /// store is installed before its JSONL snapshot is loaded so socket
    /// ingress can be accepted immediately; restored rows therefore need a
    /// second expiry/watcher pass once ``WorkstreamStore.start()`` completes.
    @MainActor
    func reconcileRestoredPendingItems() {
        reconcilePendingItems()
    }

    /// Joins the Workstream JSONL and revision-sidecar writes before an
    /// orderly application termination is acknowledged by AppKit.
    @MainActor
    func flushPersistenceForTermination() async {
        guard let store else { return }
        if !(await store.flushPersistence()) {
            // Quit must not describe a completed attempt as a durable save.
            // Raw filesystem details were logged privately by the store.
            StartupBreadcrumbLog.append("feed.persistence.flush.failed")
        }
    }
}
