import CmuxNextLayout
import Testing

/// Workspace scaling (gap:theme:lp-taste-workspace-scaling-constant-time): Cmd-N's membership reconcile
/// (`WindowManager.reconcileMembership` → `WindowRegistry.reconcile`) re-sorted every window's list on every
/// workspace-set change, n log n in the workspaces. A list already in the sidebar's order is kept as it is now:
/// `sortedLists` counts the sorts, and it stays 0 at 8 and at 5,000 workspaces.
@Suite struct WindowRegistryReconcileScalingTests {
    private func registry(_ n: Int) -> (WindowRegistry, [String]) {
        let ids = (0..<n).map { "ws\($0)" }
        var registry = WindowRegistry()
        _ = registry.openWindow(id: "w", workspaceIDs: ids)
        return (registry, ids)
    }

    @Test(arguments: [8, 5000]) func aNewWorkspaceAtTheEndSortsNoList(n: Int) {
        var (registry, ids) = registry(n)
        let before = registry.sortedLists
        registry.reconcile(live: ids + ["new"], dead: [], fallbackWindow: "w")
        #expect(registry.sortedLists - before == 0, "Cmd-N re-sorted a list already in order at \(n) workspaces")
        #expect(registry.owner(of: "new") == "w")
        #expect(registry.window("w")?.workspaceIDs == ids + ["new"])
    }

    @Test(arguments: [8, 5000]) func aClosedWorkspaceSortsNoList(n: Int) {
        var (registry, ids) = registry(n)
        let before = registry.sortedLists
        registry.reconcile(live: Array(ids.dropFirst()), dead: [ids[0]], fallbackWindow: "w")
        #expect(registry.sortedLists - before == 0, "a close re-sorted a list already in order at \(n) workspaces")
        #expect(registry.window("w")?.workspaceIDs == Array(ids.dropFirst()))
    }

    /// The skip only skips: a list out of the sidebar's order still takes that order.
    @Test func aListOutOfOrderStillSorts() {
        var (registry, ids) = registry(8)
        let reordered = Array(ids.reversed())
        registry.reconcile(live: reordered, dead: [], fallbackWindow: "w")
        #expect(registry.sortedLists > 0)
        #expect(registry.window("w")?.workspaceIDs == reordered)
    }
}
