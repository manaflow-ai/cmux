import Foundation
import Testing
@testable import CmuxNextDaemon

/// The `overlay` bench (`scripts/bench/benches/overlay.py`): intent to overlay, the main-thread time of
/// `DaemonStore.intend` (the overlay's rule, its record writes and their publication) for the intents whose overlay
/// rules are cmux-layout-reducer `optimistic` (#37429): a split, New Column and Split Left on screens of 2, 64 and 256
/// panes, a tab move in a pane of 50 tabs and a workspace move among 200. Each sample is one intend; the intent is
/// rejected after it (outside the clock), so every sample starts from the same records. Prints one
/// `OVERLAY-BENCH {json}` line per scenario with its samples in ns. It compiles and runs at a base without #37429
/// too, so the bench's before and after are the same code.
/// It runs only when named (`CMUX_SWIFT_TEST_SUITES=OptimisticOverlayBench`), never in the ordinary suites.
@MainActor
@Suite("OptimisticOverlayBench", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["CMUX_SWIFT_TEST_SUITES"]?.contains("OptimisticOverlayBench") == true))
struct OptimisticOverlayBench {
    static let warmups = 30
    static let samples = 300
    private static let key = WorkspaceKey(rawValue: "00000000-0000-4000-8000-0000000000b1")

    /// A right-leaning chain of `count` panes (handles 1...count) with daemon split handles, as one screen.
    private static func chain(_ count: Int) -> LayoutNode {
        var node = LayoutNode.leaf(PaneID(rawValue: UInt64(count)))
        for pane in stride(from: count - 1, through: 1, by: -1) {
            node = .split(id: SplitID(rawValue: UInt64(1000 + pane)), resourceID: nil, direction: pane % 2 == 0 ? .down : .right,
                          ratio: 0.5, a: .leaf(PaneID(rawValue: UInt64(pane))), b: node)
        }
        return node
    }

    private static func panes(_ count: Int, tabs: Int = 1) -> [PaneSnapshot] {
        (1...count).map { pane in
            PaneSnapshot(id: PaneID(rawValue: UInt64(pane)),
                         tabs: (0..<tabs).map { TabSnapshot(surface: SurfaceID(rawValue: UInt64(pane * 1000 + $0))) })
        }
    }

    private static func store(panes count: Int, tabs: Int = 1, workspaces extra: Int = 0) -> DaemonStore {
        let store = DaemonStore()
        let screen = ScreenSnapshot(id: ScreenID(rawValue: 2), active: true, activePane: PaneID(rawValue: UInt64(count)),
                                    layout: chain(count), panes: panes(count, tabs: tabs))
        var workspaces = [WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: key, name: "1", screens: [screen])]
        for index in 0..<extra {
            let id = UInt64(10_000 + index)
            let screen = ScreenSnapshot(id: ScreenID(rawValue: id), active: true, activePane: PaneID(rawValue: id),
                                        layout: .leaf(PaneID(rawValue: id)),
                                        panes: [PaneSnapshot(id: PaneID(rawValue: id), tabs: [TabSnapshot(surface: SurfaceID(rawValue: id))])])
            workspaces.append(WorkspaceSnapshot(id: WorkspaceHandle(rawValue: id),
                                                key: WorkspaceKey(rawValue: String(format: "00000000-0000-4000-8000-%012d", index)),
                                                name: "w\(index)", screens: [screen]))
        }
        store.apply(snapshot: DaemonTree(workspaceRevision: 1, workspaces: workspaces))
        return store
    }

    /// Bench-only ref: cmux-layout-reducer's patch answer (#46449) for the split, Split Left and New Column requests
    /// these screens send, built from the request as the Rust rule builds it, standing in for the app FFI until its
    /// release carries the patch contract. Its own cost (one small JSONSerialization parse and write) is in the samples,
    /// in place of the Rust call's; the Rust side is measured on its own (layout_tree_stress sweep).
    private static func standIn(_ request: Data) -> Data? {
        guard let r = try? JSONSerialization.jsonObject(with: request) as? [String: Any], r["op"] as? String == "split",
              let facts = r["facts"] as? [String: Any], let target = r["target"] as? UInt64, let leaf = r["leaf"] as? UInt64,
              let splitID = r["split_id"] as? String, let dir = r["dir"] as? String, let ratio = r["ratio"] as? Double,
              let panes = facts["panes"] as? Int, facts["leaf_placed"] as? Bool != true else { return nil }
        let leafPart: [String: Any] = ["type": "leaf", "pane": leaf]
        var answer: [String: Any]
        if let column = r["column"] as? [String: Any], let handle = column["handle"] as? UInt64, let width = column["width"] as? Double {
            let span = facts["span"] as? [Int]
            answer = [
                "columns": [["edit": "insert", "at": 0, "id": handle | (1 << 61), "width": 1.0, "layout": ["type": "screen"]],
                            ["edit": "insert", "at": 1, "id": handle, "width": width, "layout": leafPart]],
                "layout": ["type": "split", "dir": "right", "ratio": 0.5, "a": ["type": "screen"], "b": leafPart],
                "pane_at": min(span.map { $0[1] + 1 } ?? panes, panes),
            ]
        } else {
            guard let spots = r["spots"] as? [[String: Any]], let node = spots.first?["node"] as? [String: Any],
                  node["pane"] as? UInt64 == target else { return nil }
            let before = r["before"] as? Bool == true
            let targetPart: [String: Any] = ["type": "leaf", "pane": target]
            let index = facts["target_index"] as? Int
            answer = [
                "spots": [["spot": 0, "node": ["type": "split", "split_id": splitID, "dir": dir, "ratio": ratio,
                                               "a": before ? leafPart : targetPart, "b": before ? targetPart : leafPart]]],
                "pane_at": min(before ? (index ?? panes) : (index.map { $0 + 1 } ?? panes), panes),
            ]
        }
        return try? JSONSerialization.data(withJSONObject: answer)
    }

    /// `measure` with ``standIn(_:)`` answering the split rules; every sample must show the new pane.
    private static func measurePatch(_ store: DaemonStore, panes count: Int, _ make: () -> Intent) -> [UInt64] {
        store.benchOptimisticResponder = standIn
        defer { store.benchOptimisticResponder = nil }
        var shown = 0
        let out = measure(store, make, after: { shown += $0.workspaces.first?.screens.first?.panes.count == count + 1 ? 1 : 0 })
        #expect(shown == warmups + samples)
        return out
    }

    /// `warmups + samples` intends of `make()`'s intent, each rejected after its sample; the samples in ns.
    private static func measure(_ store: DaemonStore, _ make: () -> Intent, after: (DaemonStore) -> Void = { _ in }) -> [UInt64] {
        var out: [UInt64] = []
        out.reserveCapacity(samples)
        for index in 0..<(warmups + samples) {
            let intent = make()
            let transaction = ClientTransactionID.generate()
            let start = DispatchTime.now().uptimeNanoseconds
            store.intend(intent, transaction: transaction)
            let end = DispatchTime.now().uptimeNanoseconds
            after(store)
            store.rejectIntent(transaction)
            if index >= warmups { out.append(end - start) }
        }
        return out
    }

    private static func report(_ scenario: String, panes: Int, _ samples: [UInt64]) {
        let sorted = samples.sorted()
        let p50 = sorted[sorted.count / 2]
        let p95 = sorted[min(sorted.count - 1, Int((Double(sorted.count) * 0.95).rounded(.up)) - 1)]
        let list = samples.map(String.init).joined(separator: ",")
        print("OVERLAY-BENCH {\"scenario\":\"\(scenario)\",\"panes\":\(panes),\"unit\":\"ns\",\"p50\":\(p50),\"p95\":\(p95),\"samples\":[\(list)]}")
    }

    @Test(arguments: [2, 64, 256])
    func split(panes count: Int) throws {
        let store = Self.store(panes: count)
        let target = PaneID(rawValue: UInt64(count))
        let samples = Self.measurePatch(store, panes: count) { .splitPane(pane: target, direction: .right, ratio: 0.5, provisional: ProvisionalPane()) }
        #expect(store.mirrorViolations.isEmpty)
        Self.report("split", panes: count, samples)
    }

    @Test(arguments: [2, 64, 256])
    func splitLeft(panes count: Int) throws {
        let store = Self.store(panes: count)
        let target = PaneID(rawValue: UInt64(count))
        let samples = Self.measurePatch(store, panes: count) {
            .splitPane(pane: target, direction: .right, ratio: 0.5, provisional: ProvisionalPane().placed(before: true))
        }
        #expect(store.mirrorViolations.isEmpty)
        Self.report("split_left", panes: count, samples)
    }

    @Test(arguments: [2, 64, 256])
    func newColumn(panes count: Int) throws {
        let store = Self.store(panes: count)
        let target = PaneID(rawValue: UInt64(count))
        let samples = Self.measurePatch(store, panes: count) {
            .splitPane(pane: target, direction: .right, ratio: 0.5, provisional: ProvisionalPane(columnWidth: 0.5))
        }
        #expect(store.mirrorViolations.isEmpty)
        Self.report("new_column", panes: count, samples)
    }

    @Test func moveTab() throws {
        let store = Self.store(panes: 1, tabs: 50)
        let samples = Self.measure(store) { .moveTab(surface: SurfaceID(rawValue: 1000), toPane: PaneID(rawValue: 1), index: 40) }
        #expect(store.mirrorViolations.isEmpty)
        Self.report("move_tab", panes: 1, samples)
    }

    @Test func moveWorkspace() throws {
        let store = Self.store(panes: 1, workspaces: 199)
        let samples = Self.measure(store) { .moveWorkspace(key: Self.key, index: 150) }
        #expect(store.mirrorViolations.isEmpty)
        Self.report("move_workspace", panes: 1, samples)
    }
}
