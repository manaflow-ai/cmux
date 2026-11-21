import Foundation
import Testing
@testable import CmuxNextDaemon

/// The `overlay` bench (`scripts/bench/benches/overlay.py`): intent to overlay, the main-thread time of
/// `DaemonStore.intend` (the overlay's rule, its record writes and their publication) for the intents whose overlay
/// rules are cmux-layout-reducer `optimistic` (#37429): a split, New Column and Split Left on screens of 2, 64 and 256
/// panes (a right-leaning chain, whose target is its deepest pane, and a balanced tree: scenarios `*_balanced`), a tab move in a pane of 50 tabs and a workspace move among 200. Each sample is one intend; the intent is
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

    /// A balanced tree of panes `range` (depth log2 of the count), as a realistic layout is: each split halves its
    /// panes, alternating direction by depth.
    private static func balanced(_ range: ClosedRange<Int>, depth: Int = 0) -> LayoutNode {
        guard range.count > 1 else { return .leaf(PaneID(rawValue: UInt64(range.lowerBound))) }
        let mid = range.lowerBound + range.count / 2 - 1
        return .split(id: SplitID(rawValue: UInt64(1000 + mid)), resourceID: nil, direction: depth % 2 == 0 ? .right : .down,
                      ratio: 0.5, a: balanced(range.lowerBound...mid, depth: depth + 1),
                      b: balanced((mid + 1)...range.upperBound, depth: depth + 1))
    }

    private static func panes(_ count: Int, tabs: Int = 1) -> [PaneSnapshot] {
        (1...count).map { pane in
            PaneSnapshot(id: PaneID(rawValue: UInt64(pane)),
                         tabs: (0..<tabs).map { TabSnapshot(surface: SurfaceID(rawValue: UInt64(pane * 1000 + $0))) })
        }
    }

    /// One screen of `count` panes: a ``chain(_:)`` (the target the deepest pane), or ``balanced(_:depth:)``.
    private static func store(panes count: Int, tabs: Int = 1, workspaces extra: Int = 0, balanced isBalanced: Bool = false) -> DaemonStore {
        let store = DaemonStore()
        let screen = ScreenSnapshot(id: ScreenID(rawValue: 2), active: true, activePane: PaneID(rawValue: UInt64(count)),
                                    layout: isBalanced ? balanced(1...count) : chain(count), panes: panes(count, tabs: tabs))
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

    /// `warmups + samples` intends of `make()`'s intent, each rejected after its sample; the samples in ns.
    private static func measure(_ store: DaemonStore, _ make: () -> Intent) -> [UInt64] {
        var out: [UInt64] = []
        out.reserveCapacity(samples)
        for index in 0..<(warmups + samples) {
            let intent = make()
            let transaction = ClientTransactionID.generate()
            let start = DispatchTime.now().uptimeNanoseconds
            store.intend(intent, transaction: transaction)
            let end = DispatchTime.now().uptimeNanoseconds
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

    @Test(arguments: [false, true], [2, 64, 256])
    func split(balanced: Bool, panes count: Int) throws {
        let store = Self.store(panes: count, balanced: balanced)
        let target = PaneID(rawValue: UInt64(count))
        let samples = Self.measure(store) { .splitPane(pane: target, direction: .right, ratio: 0.5, provisional: ProvisionalPane()) }
        #expect(store.mirrorViolations.isEmpty)
        Self.report("split" + (balanced ? "_balanced" : ""), panes: count, samples)
    }

    @Test(arguments: [false, true], [2, 64, 256])
    func splitLeft(balanced: Bool, panes count: Int) throws {
        let store = Self.store(panes: count, balanced: balanced)
        let target = PaneID(rawValue: UInt64(count))
        let samples = Self.measure(store) {
            .splitPane(pane: target, direction: .right, ratio: 0.5, provisional: ProvisionalPane().placed(before: true))
        }
        #expect(store.mirrorViolations.isEmpty)
        Self.report("split_left" + (balanced ? "_balanced" : ""), panes: count, samples)
    }

    @Test(arguments: [false, true], [2, 64, 256])
    func newColumn(balanced: Bool, panes count: Int) throws {
        let store = Self.store(panes: count, balanced: balanced)
        let target = PaneID(rawValue: UInt64(count))
        let samples = Self.measure(store) {
            .splitPane(pane: target, direction: .right, ratio: 0.5, provisional: ProvisionalPane(columnWidth: 0.5))
        }
        #expect(store.mirrorViolations.isEmpty)
        Self.report("new_column" + (balanced ? "_balanced" : ""), panes: count, samples)
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
