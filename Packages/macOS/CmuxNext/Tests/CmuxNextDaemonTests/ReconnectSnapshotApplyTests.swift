@testable import CmuxNextDaemon
import Foundation
import Testing

/// hq#19373 (Leo, ask c-ea62b204f6: "a graceful if not imperceptible state transition all around"): after a
/// daemon reconnect the first snapshot applies in full (`applyTree` + `rebuildIndex`, the epoch check in
/// `incrementalDiff`). It reconciles every record by identity, so the sidebar must not move, blink or lose a
/// row, and nothing a row reads may be written. These tests prove that and print what the full pass costs
/// next to an unchanged incremental one, from the same harness.
@MainActor @Suite struct ReconnectSnapshotApplyTests {
    private static let groups = [WorkspaceGroupSnapshot(id: "g0", name: "Group 0", index: 0),
                                 WorkspaceGroupSnapshot(id: "g1", name: "Group 1", index: 1)]

    /// One workspace: one screen, one pane, 3 tabs; every third is ungrouped, the rest split over two groups.
    private static func workspace(_ index: Int) -> WorkspaceSnapshot {
        let base = UInt64(index * 100)
        let pane = PaneSnapshot(id: PaneID(rawValue: base + 1),
                                tabs: (0..<3).map { TabSnapshot(surface: SurfaceID(rawValue: base + 10 + UInt64($0)), title: "t \($0)") })
        let screen = ScreenSnapshot(id: ScreenID(rawValue: base + 2), layout: .leaf(PaneID(rawValue: base + 1)), panes: [pane])
        var snapshot = WorkspaceSnapshot(id: WorkspaceHandle(rawValue: base + 3), key: nil, name: "w\(index)", screens: [screen])
        snapshot.group = index % 3 == 0 ? nil : WorkspaceGroupID(rawValue: "g\(index % 2)")
        return snapshot
    }

    private static func session(_ count: Int) -> DaemonTree {
        DaemonTree(workspaces: (0..<count).map(workspace), groups: groups)
    }

    private static func reconnect(_ store: DaemonStore, serial: UInt64) {
        _ = store.apply(.disconnected(reason: "link dropped"))
        let envelope = DaemonEventEnvelope(sequence: DaemonEventEnvelope.sequence(serial: serial, index: 0),
                                           event: .connected(DaemonIdentity(generation: "boot"), generationChanged: false), sourceID: UUID())
        _ = store.apply(batch: [envelope])
    }

    @MainActor private final class Fired { var names: [String] = [] }

    /// Everything a sidebar row and section reads, tracked: a write to any of it after the reconnect would
    /// redraw, move or reset a row.
    private static func track(_ store: DaemonStore, into fired: Fired) {
        withObservationTracking { _ = store.sidebarSections; _ = store.workspaces; _ = store.groups } onChange: {
            MainActor.assumeIsolated { fired.names.append("store lists") }
        }
        for workspace in store.workspaces {
            withObservationTracking {
                _ = (workspace.name, workspace.group, workspace.title, workspace.color, workspace.icon, workspace.pinned)
                _ = (workspace.screens, workspace.screens.flatMap(\.panes).map(\.tabs))
                for tab in workspace.screens.flatMap(\.panes).flatMap(\.tabs) { _ = tab.titleText }
            } onChange: { MainActor.assumeIsolated { fired.names.append(workspace.name) } }
        }
    }

    @Test(arguments: [500, 3000])
    func aReconnectsFullSnapshotLeavesEverySidebarRowAsItWas(sessionSize: Int) throws {
        let store = DaemonStore()
        Self.reconnect(store, serial: 1)
        store.apply(snapshot: Self.session(sessionSize))
        let sections = store.sidebarSections, models = store.workspaces
        let tabs = models.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs)
        try #require(sections.count == 3 && models.count == sessionSize)

        Self.reconnect(store, serial: 2)
        #expect(store.incrementalDiff(Self.session(sessionSize), diff: nil) == nil, "setup: a new connection's first snapshot applies in full")
        let fired = Fired()
        Self.track(store, into: fired)
        let before = store.index.indexedRecords
        store.apply(snapshot: Self.session(sessionSize))

        #expect(store.index.indexedRecords - before == sessionSize * 6, "the pass is the full one")
        #expect(fired.names.isEmpty, "the reconnect wrote what \(fired.names.count) sidebar rows read: \(fired.names.prefix(5))")
        #expect(zip(store.workspaces, models).allSatisfy { $0 === $1 }, "every workspace keeps its record (its row and selection)")
        #expect(zip(store.workspaces.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs), tabs).allSatisfy { $0 === $1 })
        #expect(store.sidebarSections.count == sections.count
            && zip(store.sidebarSections, sections).allSatisfy { $0.group === $1.group && zip($0.workspaces, $1.workspaces).allSatisfy { $0 === $1 } })
    }

    /// The number hq#19373 asks for: the main-thread time of the reconnect's full pass, beside an unchanged
    /// incremental snapshot of the same session (median of 7). Printed, not gated: a test machine is not his Mac.
    @Test(arguments: [500, 3000])
    func reconnectFullPassCost(sessionSize: Int) {
        let store = DaemonStore()
        Self.reconnect(store, serial: 1)
        store.apply(snapshot: Self.session(sessionSize))
        let clock = ContinuousClock()
        func median(_ durations: [Duration]) -> Double {
            let sorted = durations.sorted()
            let middle = sorted[sorted.count / 2].components
            return Double(middle.seconds) * 1000 + Double(middle.attoseconds) / 1e15
        }
        var full: [Duration] = [], incremental: [Duration] = []
        for round in 0..<7 {
            let tree = Self.session(sessionSize)
            Self.reconnect(store, serial: UInt64(round + 2))
            full.append(clock.measure { store.apply(snapshot: tree) })
            let again = Self.session(sessionSize)
            incremental.append(clock.measure { store.apply(snapshot: again) })
        }
        print(String(format: "reconnect-apply workspaces=%d tabs=%d full_ms=%.2f incremental_ms=%.2f",
                     sessionSize, sessionSize * 3, median(full), median(incremental)))
        #expect(store.workspaces.count == sessionSize)
    }
}
