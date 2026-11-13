@testable import CmuxNextDaemon
import Foundation
import Testing

/// Leo 2026-11-04: "never ... acceptable ... linear time growth degradation". The main-thread part of a `tree-changed`
/// that changed one workspace (its diff computed off main, as a live resync does) costs the same at 3,000 workspaces
/// as at 100.
///
/// Two things kept this from judging the apply. Debug builds (these tests) walk the whole tree for the mirror check
/// once per second of wall clock (``DaemonStore/mirrorCheckInterval``), on whichever apply crosses the second, so a
/// slow runner put more walks of a bigger tree into the timed applies; the timed section now runs with the check
/// suspended (``DaemonStore/withMirrorCheckSuspended(_:)``). And the mean of a round let a few slow samples move the
/// result; the cost is now the median of many single applies, taken in interleaved rounds over the three sizes, so a
/// load burst on a shared runner lands on every size alike. A cost every apply pays still moves the median, so an
/// O(workspaces) apply still fails the 4x limit.
@MainActor @Suite(.serialized) struct SnapshotApplyScaleTests {
    static let sizes = [100, 1000, 3000]

    static func session(_ count: Int, title: String, at changed: Int) -> DaemonTree {
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
    /// `beforeEach` runs untimed before each apply (the forced-check test resets the check's interval there).
    static func applyCosts(_ store: DaemonStore, count: Int, applies: Int, round: Int,
                           beforeEach: (Int) -> Void = { _ in }) async -> [UInt64] {
        var costs: [UInt64] = []
        costs.reserveCapacity(applies)
        for i in 0..<applies {
            let next = session(count, title: "r\(round)-\(i)", at: count / 2)
            let diff = await store.snapshotDiff(of: next)
            beforeEach(i)
            let begin = DispatchTime.now().uptimeNanoseconds
            store.apply(snapshot: next, diff: diff)
            costs.append(DispatchTime.now().uptimeNanoseconds - begin)
        }
        return costs
    }

    static func median(_ samples: [UInt64]) -> Double {
        let sorted = samples.sorted()
        guard !sorted.isEmpty else { return 0 }
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (Double(sorted[middle - 1]) + Double(sorted[middle])) / 2 : Double(sorted[middle])
    }

    /// One store per size, each loaded and warmed up.
    static func warmStores() async -> [Int: DaemonStore] {
        var stores: [Int: DaemonStore] = [:]
        for count in sizes {
            let store = DaemonStore()
            store.apply(snapshot: session(count, title: "t", at: -1))
            _ = await applyCosts(store, count: count, applies: 5, round: -1) // warm up
            stores[count] = store
        }
        return stores
    }

    /// Per-apply costs of interleaved rounds over every size: `rounds` rounds of `applies` applies each.
    static func interleavedCosts(_ stores: [Int: DaemonStore], rounds: Int = 9, applies: Int = 20,
                                 beforeEach: (Int) -> Void = { _ in }) async throws -> [Int: [UInt64]] {
        var costs: [Int: [UInt64]] = [:]
        for round in 0..<rounds {
            for count in sizes {
                let store = try #require(stores[count])
                costs[count, default: []] += await applyCosts(store, count: count, applies: applies, round: round, beforeEach: beforeEach)
            }
        }
        return costs
    }

    @Test func aOneWorkspaceSnapshotCostsTheMainThreadTheSameAt3000WorkspacesAsAt100() async throws {
        let stores = await Self.warmStores()
        let walkedBefore = stores.mapValues { ($0.snapshotWorkspacesWalkedOnMain, $0.workspaceListWalkedOnMain) }
        // The mirror check is a debug-build walk of the whole tree, not part of the apply: off while timed.
        var suspended: [DaemonStore] = []
        for count in Self.sizes { suspended.append(try #require(stores[count])) }
        let costs = try await Self.suspendingMirrorChecks(of: suspended) {
            try await Self.interleavedCosts(stores)
        }
        for count in Self.sizes {
            let store = try #require(stores[count])
            let before = try #require(walkedBefore[count])
            // The work itself: no workspace snapshot compared and no workspace list rebuilt on main.
            #expect(store.snapshotWorkspacesWalkedOnMain == before.0, "main compared workspace snapshots at \(count) workspaces")
            #expect(store.workspaceListWalkedOnMain == before.1, "main walked the workspace list at \(count) workspaces")
            #expect(store.workspaces[count / 2].screens.first?.panes.first?.tabs.first?.titleText == "r8-19")
        }
        let small = Self.median(costs[100] ?? [])
        let mid = Self.median(costs[1000] ?? [])
        let large = Self.median(costs[3000] ?? [])
        print("snapshot-apply-cost median ns/apply of \(costs[100]?.count ?? 0) N=100 \(Int(small)) N=1000 \(Int(mid)) N=3000 \(Int(large))")
        #expect(large < small * 4, "a one-workspace snapshot at 3,000 workspaces took \(Int(large)) ns on main, at 100 \(Int(small)) ns")
    }

    /// The seam stays scoped: the check resumes when the scope ends, even by a throw.
    @Test func bTheMirrorCheckResumesAfterASuspensionThatThrows() async throws {
        struct Thrown: Error {}
        let store = DaemonStore()
        store.apply(snapshot: Self.session(10, title: "t", at: -1))
        await #expect(throws: Thrown.self) {
            try await store.withMirrorCheckSuspended {
                store.apply(snapshot: Self.session(10, title: "a", at: 5))
                throw Thrown()
            }
        }
        #if DEBUG
        #expect(store.mirrorCheckSuspensions == 0)
        store.apply(snapshot: Self.session(10, title: "b", at: 5))
        #expect(store.mirrorFingerprint != nil, "the first writer after the scope records the mirror again")
        #endif
    }

    /// Nests one suspension per store around `body`.
    static func suspendingMirrorChecks<T>(of stores: ArraySlice<DaemonStore>, _ body: () async throws -> T) async throws -> T {
        guard let first = stores.first else { return try await body() }
        return try await first.withMirrorCheckSuspended {
            try await suspendingMirrorChecks(of: stores.dropFirst(), body)
        }
    }

    static func suspendingMirrorChecks<T>(of stores: [DaemonStore], _ body: () async throws -> T) async throws -> T {
        try await suspendingMirrorChecks(of: stores[...], body)
    }
}
