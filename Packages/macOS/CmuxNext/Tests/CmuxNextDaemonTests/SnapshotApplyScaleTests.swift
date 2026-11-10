@testable import CmuxNextDaemon
import Foundation
import Testing

/// Leo 2026-11-04: "never ... acceptable ... linear time growth degradation". The main-thread part of a `tree-changed`
/// that changed one workspace (its diff computed off main, as a live resync does) costs the same at 3,000 workspaces
/// as at 100.
///
/// The cost is the median of many single applies, taken in interleaved rounds over the three session sizes. The mean
/// is not used: debug builds (these tests) walk the whole tree for the mirror check at most once per second of wall
/// clock (``DaemonStore/mirrorCheckInterval``), so the few applies that take that walk depend on how slow the runner
/// was, not on the apply; release builds skip it. A cost that every apply pays moves the median, so an O(workspaces)
/// apply still fails. Interleaving puts a load burst on the shared runner on every size alike.
@MainActor @Suite(.serialized) struct SnapshotApplyScaleTests {
    private static let sizes = [100, 1000, 3000]

    private static func session(_ count: Int, title: String, at changed: Int) -> DaemonTree {
        DaemonTree(workspaces: (0..<count).map { index in
            let base = UInt64(index * 100)
            let pane = PaneSnapshot(id: PaneID(rawValue: base + 1),
                                    tabs: [TabSnapshot(surface: SurfaceID(rawValue: base + 10), title: index == changed ? title : "t")])
            let screen = ScreenSnapshot(id: ScreenID(rawValue: base + 2), layout: .leaf(PaneID(rawValue: base + 1)), panes: [pane])
            return WorkspaceSnapshot(id: WorkspaceHandle(rawValue: base + 3), key: nil, name: "w\(index)", screens: [screen])
        })
    }

    /// Main-thread nanoseconds of each of `applies` one-workspace snapshot applies to `store`, which holds `count`
    /// workspaces; each snapshot renames the middle workspace's tab, and its diff is computed off main first.
    private static func applyCosts(_ store: DaemonStore, count: Int, applies: Int, round: Int) async -> [UInt64] {
        var costs: [UInt64] = []
        costs.reserveCapacity(applies)
        for i in 0..<applies {
            let next = session(count, title: "r\(round)-\(i)", at: count / 2)
            let diff = await store.snapshotDiff(of: next)
            let begin = DispatchTime.now().uptimeNanoseconds
            store.apply(snapshot: next, diff: diff)
            costs.append(DispatchTime.now().uptimeNanoseconds - begin)
        }
        return costs
    }

    private static func median(_ samples: [UInt64]) -> Double {
        let sorted = samples.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (Double(sorted[middle - 1]) + Double(sorted[middle])) / 2 : Double(sorted[middle])
    }

    @Test func aOneWorkspaceSnapshotCostsTheMainThreadTheSameAt3000WorkspacesAsAt100() async throws {
        var stores: [Int: DaemonStore] = [:]
        for count in Self.sizes {
            let store = DaemonStore()
            store.apply(snapshot: Self.session(count, title: "t", at: -1))
            _ = await Self.applyCosts(store, count: count, applies: 5, round: -1) // warm up
            stores[count] = store
        }
        let walkedBefore = stores.mapValues { ($0.snapshotWorkspacesWalkedOnMain, $0.workspaceListWalkedOnMain) }
        var costs: [Int: [UInt64]] = [:]
        for round in 0..<9 {
            for count in Self.sizes {
                let store = try #require(stores[count])
                costs[count, default: []] += await Self.applyCosts(store, count: count, applies: 20, round: round)
            }
        }
        for count in Self.sizes {
            let store = try #require(stores[count])
            let before = try #require(walkedBefore[count])
            // The work itself: no workspace snapshot compared and no workspace list rebuilt on main.
            #expect(store.snapshotWorkspacesWalkedOnMain == before.0, "main compared workspace snapshots at \(count) workspaces")
            #expect(store.workspaceListWalkedOnMain == before.1, "main walked the workspace list at \(count) workspaces")
            #expect(store.workspaces[count / 2].screens.first?.panes.first?.tabs.first?.title == "r8-19")
        }
        let small = Self.median(costs[100] ?? [])
        let mid = Self.median(costs[1000] ?? [])
        let large = Self.median(costs[3000] ?? [])
        print("snapshot-apply-cost median ns/apply of \(costs[100]?.count ?? 0) N=100 \(Int(small)) N=1000 \(Int(mid)) N=3000 \(Int(large))")
        #expect(large < small * 4, "a one-workspace snapshot at 3,000 workspaces took \(Int(large)) ns on main, at 100 \(Int(small)) ns")
    }
}
