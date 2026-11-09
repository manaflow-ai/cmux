@testable import CmuxNextDaemon
import Foundation
import Testing

/// Leo 2026-11-04: "never ... acceptable ... linear time growth degradation". The main-thread part of a `tree-changed`
/// that changed one workspace (its diff computed off main, as a live resync does) costs the same at 3,000 workspaces
/// as at 100.
@MainActor @Suite(.serialized) struct SnapshotApplyScaleTests {
    private static func session(_ count: Int, title: String, at changed: Int) -> DaemonTree {
        DaemonTree(workspaces: (0..<count).map { index in
            let base = UInt64(index * 100)
            let pane = PaneSnapshot(id: PaneID(rawValue: base + 1),
                                    tabs: [TabSnapshot(surface: SurfaceID(rawValue: base + 10), title: index == changed ? title : "t")])
            let screen = ScreenSnapshot(id: ScreenID(rawValue: base + 2), layout: .leaf(PaneID(rawValue: base + 1)), panes: [pane])
            return WorkspaceSnapshot(id: WorkspaceHandle(rawValue: base + 3), key: nil, name: "w\(index)", screens: [screen])
        })
    }

    /// Main-thread nanoseconds per one-workspace snapshot apply over `count` workspaces, best of three rounds.
    static func applyCost(_ count: Int, applies: Int = 60) async -> Double {
        let store = DaemonStore()
        store.apply(snapshot: session(count, title: "t", at: -1))
        var best = Double.infinity
        for round in 0..<3 {
            var total: UInt64 = 0
            for i in 0..<applies {
                let next = session(count, title: "r\(round)-\(i)", at: count / 2)
                let diff = await store.snapshotDiff(of: next)
                let begin = DispatchTime.now().uptimeNanoseconds
                store.apply(snapshot: next, diff: diff)
                total += DispatchTime.now().uptimeNanoseconds - begin
            }
            best = min(best, Double(total) / Double(applies))
        }
        return best
    }

    @Test func aOneWorkspaceSnapshotCostsTheMainThreadTheSameAt3000WorkspacesAsAt100() async {
        _ = await Self.applyCost(100, applies: 10) // warm up
        let small = await Self.applyCost(100)
        let mid = await Self.applyCost(1000)
        let large = await Self.applyCost(3000)
        print("snapshot-apply-cost ns/apply N=100 \(Int(small)) N=1000 \(Int(mid)) N=3000 \(Int(large))")
        #expect(large < small * 4, "a one-workspace snapshot at 3,000 workspaces took \(Int(large)) ns on main, at 100 \(Int(small)) ns")
    }
}
