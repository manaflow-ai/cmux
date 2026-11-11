@testable import CmuxNextDaemon
import Foundation
import Testing

/// Leo 2026-11-04: "never ... acceptable ... linear time growth degradation". Every live snapshot built a fresh
/// N-long workspace order array (`SnapshotDiff.order`), and the memo took it, releasing its old one on the main
/// thread, even when no workspace moved. A snapshot in the memo's order keeps the memo's array: no order array is
/// made or freed for it, at 100 workspaces or at 3,000.
@MainActor @Suite struct SnapshotOrderArrayTests {
    private func workspace(_ index: Int, title: String = "t") -> WorkspaceSnapshot {
        let base = UInt64(index * 100)
        let pane = PaneSnapshot(id: PaneID(rawValue: base + 1), tabs: [TabSnapshot(surface: SurfaceID(rawValue: base + 10), title: title)])
        let screen = ScreenSnapshot(id: ScreenID(rawValue: base + 2), layout: .leaf(PaneID(rawValue: base + 1)), panes: [pane])
        return WorkspaceSnapshot(id: WorkspaceHandle(rawValue: base + 3), key: nil, name: "w\(index)", screens: [screen])
    }

    private func session(_ count: Int, changing changed: Int? = nil) -> DaemonTree {
        DaemonTree(workspaces: (0..<count).map { workspace($0, title: $0 == changed ? "renamed \($0)" : "t") })
    }

    /// Order elements allocated per snapshot over `count` workspaces: each snapshot changes one workspace and moves
    /// none; an order array the memo did not hold before counts its length. Off-main diffs when `offMain`, else the
    /// diff the apply computes itself.
    private func orderElementsPerSnapshot(_ count: Int, offMain: Bool, rounds: Int = 5) async -> Double {
        let store = DaemonStore()
        store.apply(snapshot: session(count))
        var allocated = 0
        for round in 0..<rounds {
            let next = session(count, changing: 7 + round)
            let memoOrder = store.snapshotMemo.order
            let diff = offMain ? await store.snapshotDiff(of: next) : nil
            if let diff, !diff.order.sharesStorage(with: memoOrder) { allocated += diff.order.count }
            store.apply(snapshot: next, diff: diff)
            // The memo let its old order go (freed on main, as the diff's array is not the old one).
            if diff == nil, !store.snapshotMemo.order.sharesStorage(with: memoOrder) { allocated += count }
            #expect(store.workspaces[7 + round].screens.first?.panes.first?.tabs.first?.titleText == "renamed \(7 + round)")
        }
        #expect(store.snapshotMemo.order == session(count).workspaces.map(WorkspaceModel.identity))
        return Double(allocated) / Double(rounds)
    }

    @Test func aSnapshotThatMovedNoWorkspaceMakesNoOrderArrayAt100OrAt3000Workspaces() async {
        let small = await orderElementsPerSnapshot(100, offMain: true)
        let large = await orderElementsPerSnapshot(3000, offMain: true)
        let smallMain = await orderElementsPerSnapshot(100, offMain: false)
        let largeMain = await orderElementsPerSnapshot(3000, offMain: false)
        print("snapshot-order-elements/snapshot off-main N=100 \(small) N=3000 \(large) on-main N=100 \(smallMain) N=3000 \(largeMain)")
        #expect(small == 0 && large == 0, "an unmoved snapshot made order arrays: \(small) elements at 100, \(large) at 3,000")
        #expect(smallMain == 0 && largeMain == 0, "an unmoved snapshot made order arrays on main: \(smallMain) at 100, \(largeMain) at 3,000")
    }

    /// A snapshot that moves, adds, drops the last or drops the first workspace still records its own order.
    @Test func aSnapshotThatMovesAddsOrDropsWorkspacesRecordsItsOrder() async {
        let store = DaemonStore()
        store.apply(snapshot: session(6))
        let base = session(6).workspaces
        for workspaces in [Array(base.dropLast()), base, base + [workspace(9)], Array(base.dropFirst()), base.reversed(), base] {
            let tree = DaemonTree(workspaces: workspaces)
            store.apply(snapshot: tree, diff: await store.snapshotDiff(of: tree))
            #expect(store.snapshotMemo.order == workspaces.map(WorkspaceModel.identity))
            #expect(store.workspaces.map(\.name) == workspaces.map(\.name))
        }
    }
}
