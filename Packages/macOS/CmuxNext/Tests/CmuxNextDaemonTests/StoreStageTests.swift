import CmuxNextCompat
import Foundation
import Observation
import Testing
@testable import CmuxNextDaemon

/// A clock whose sleeps end at once: a stage's deadline passes on the next turn.
private struct ElapsedClock: Clock {
    struct Instant: InstantProtocol {
        var offset: Duration
        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    var now: Instant { Instant(offset: .zero) }
    var minimumResolution: Duration { .zero }
    func sleep(until deadline: Instant, tolerance: Duration?) async throws {}
}

/// Set once from an observation's change callback (called synchronously inside the mutation).
private final class ChangeFlag: Sendable {
    private let value = Mutex(false)
    func set() { value.withLock { $0 = true } }
    var isSet: Bool { value.withLock { $0 } }
}

/// A script batch's changes show once (CLAUDE.md "Go past Chrome where cmux is scripted": a burst
/// of scripted changes coalesces to one model update and at most one frame per window), and never
/// delay what the person sees elsewhere or does themselves.
@MainActor
struct StoreStageTests {
    /// Workspace 1 (handle 1): pane 10 with surfaces 1...8. Workspace 2 (handle 2): pane 20 with surfaces 21, 22.
    private static func tree() -> DaemonTree {
        let busy = WorkspaceSnapshot(id: 1, key: WorkspaceKey(rawValue: "w1"), name: "scripted", screens: [
            ScreenSnapshot(id: 100, active: true, activePane: 10, layout: .leaf(10),
                           panes: [PaneSnapshot(id: 10, tabs: (1...8).map { TabSnapshot(surface: SurfaceID(rawValue: UInt64($0)), title: "t\($0)") })]),
        ])
        let other = WorkspaceSnapshot(id: 2, key: WorkspaceKey(rawValue: "w2"), name: "watched", screens: [
            ScreenSnapshot(id: 200, active: true, activePane: 20, layout: .leaf(20),
                           panes: [PaneSnapshot(id: 20, tabs: [TabSnapshot(surface: 21, title: "a"), TabSnapshot(surface: 22, title: "b")])]),
        ])
        return DaemonTree(workspaceRevision: 1, workspaces: [busy, other])
    }

    private static func store() -> DaemonStore {
        let store = DaemonStore()
        store.apply(snapshot: tree())
        return store
    }

    /// Whether `step` changed what `projection` reads (one window's view of the store).
    private static func publishes<T>(_ projection: @escaping () -> T, during step: () -> Void) -> Bool {
        let changed = ChangeFlag()
        withObservationTracking { _ = projection() } onChange: { changed.set() }
        step()
        return changed.isSet
    }

    private static func names(_ store: DaemonStore, workspace: WorkspaceHandle) -> [String?] {
        store.workspace(handle: workspace)?.screens.flatMap(\.panes).flatMap(\.tabs).map(\.name) ?? []
    }

    private static func renamed(_ surface: UInt64, _ name: String, workspace: WorkspaceHandle, pane: PaneID, screen: ScreenID) -> DaemonEvent {
        var tab = TabSnapshot(surface: SurfaceID(rawValue: surface), title: "t\(surface)")
        tab.name = name
        return .tabRenamed(TabDelta(workspace: workspace, screen: screen, pane: pane, surface: SurfaceID(rawValue: surface), index: nil, entity: tab))
    }

    /// Eight scripted renames in workspace 1 and their echoes over three drains publish to the window
    /// that shows workspace 1 once, at the commit. The window that shows workspace 2 gets its own
    /// updates in the drain they arrive in.
    @Test func aBatchPublishesOnceToItsWindowAndNeverDelaysAnother() {
        let store = Self.store()
        let scope = DaemonCommandScope()
        let stage = store.openStage(for: scope, until: .now + .seconds(60))
        let scripted = { Self.names(store, workspace: 1) }
        let watched = { store.workspace(handle: 2)?.screens.flatMap(\.panes).flatMap(\.tabs).map(\.title) ?? [] }
        var scriptedPublishes = 0
        for surface in 1...8 {
            let changed = Self.publishes(scripted) {
                DaemonCommandScope.$current.withValue(scope) {
                    store.intend(.renameTab(surface: SurfaceID(rawValue: UInt64(surface)), name: "s\(surface)"), transaction: .generate())
                }
            }
            if changed { scriptedPublishes += 1 }
        }
        var sequence: UInt64 = 0
        for chunk in [1...3, 4...6, 7...8] {
            var batch: [DaemonEventEnvelope] = chunk.map { surface in
                sequence += 1
                return DaemonEventEnvelope(sequence: sequence, event: Self.renamed(UInt64(surface), "s\(surface)", workspace: 1, pane: 10, screen: 100))
            }
            sequence += 1
            batch.append(DaemonEventEnvelope(sequence: sequence, event: .titleChanged(surface: 21, title: "a\(sequence)")))
            let title = "a\(sequence)"
            var watchedChanged = false
            let changed = Self.publishes(scripted) {
                watchedChanged = Self.publishes(watched) { _ = store.apply(batch: batch) }
            }
            if changed { scriptedPublishes += 1 }
            #expect(watchedChanged, "workspace 2's update waited for the scripted batch")
            #expect(store.tab(surface: 21)?.title == title)
        }
        #expect(scriptedPublishes == 0, "the scripted workspace showed \(scriptedPublishes) partial states before the commit")
        let committed = Self.publishes(scripted) { stage.commit() }
        #expect(committed)
        #expect(Self.names(store, workspace: 1) == (1...8).map { "s\($0)" })
        #expect(store.appliedSequence == sequence, "the commit leaves the applied sequence below an event it applied")
        #expect(!store.intentLog.hasHeld)
    }

    /// The person's own rename in a staged workspace shows at once, and the commit neither undoes
    /// nor repeats it.
    @Test func aPersonsIntentInAStagedWorkspaceShowsAtOnce() {
        let store = Self.store()
        let scope = DaemonCommandScope()
        let stage = store.openStage(for: scope, until: .now + .seconds(60))
        DaemonCommandScope.$current.withValue(scope) {
            store.intend(.renameTab(surface: 2, name: "batch"), transaction: .generate())
        }
        store.intend(.renameTab(surface: 1, name: "mine"), transaction: .generate())
        #expect(store.tab(surface: 1)?.name == "mine", "the person's rename waited for the script")
        #expect(store.tab(surface: 2)?.name == nil, "the script's rename showed before its commit")
        stage.commit()
        #expect(store.tab(surface: 1)?.name == "mine")
        #expect(store.tab(surface: 2)?.name == "batch")
        #expect(store.pendingIntents.count == 2)
    }

    /// The connection ends mid-batch: the stage commits before the disconnect applies, so no intent
    /// stays held.
    @Test func aDisconnectMidStageCommitsAndLeavesNoHeldIntent() {
        let store = Self.store()
        let scope = DaemonCommandScope()
        _ = store.openStage(for: scope, until: .now + .seconds(60))
        DaemonCommandScope.$current.withValue(scope) {
            store.intend(.renameTab(surface: 3, name: "batch"), transaction: .generate())
        }
        _ = store.apply(batch: [DaemonEventEnvelope(sequence: 1, event: Self.renamed(3, "batch", workspace: 1, pane: 10, screen: 100)),
                                DaemonEventEnvelope(sequence: 2, event: .disconnected(reason: "test"))])
        #expect(store.stage == nil)
        #expect(!store.intentLog.hasHeld)
        #expect(store.tab(surface: 3)?.name == "batch")
    }

    /// A batch whose commit never comes does not hold the store: the stage commits at its deadline.
    @Test func aStageCommitsByItselfAtItsDeadline() async {
        let store = Self.store()
        let scope = DaemonCommandScope()
        _ = store.openStage(for: scope, until: .now, clock: ElapsedClock())
        DaemonCommandScope.$current.withValue(scope) {
            store.intend(.renameTab(surface: 4, name: "batch"), transaction: .generate())
        }
        #expect(store.tab(surface: 4)?.name == nil)
        for _ in 0..<100 where store.stage != nil { await Task.yield() }
        #expect(store.stage == nil, "the stage outlived its deadline")
        #expect(store.tab(surface: 4)?.name == "batch")
    }
}
