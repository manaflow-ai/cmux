import CmuxNextCompat
import Foundation
import Observation
import Testing
@testable import CmuxNextDaemon

/// A clock that moves only when the test advances it; each sleep that starts is signalled on
/// ``sleeps``, so a test advances only once a deadline sleeps on it (no poll).
private final class StageClock: Clock, Sendable {
    struct Instant: InstantProtocol {
        var offset: Duration
        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    private struct Sleeper {
        let id: Int
        let deadline: Instant
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct State {
        var now = Instant(offset: .zero)
        var sleepers: [Sleeper] = []
        var cancelled: Set<Int> = []
        var nextID = 0
    }

    private let state = Mutex(State())
    private let slept: AsyncStream<Void>.Continuation
    /// One element per sleep that started and did not end at once.
    let sleeps: AsyncStream<Void>

    init() {
        (sleeps, slept) = AsyncStream.makeStream()
    }

    var now: Instant { state.withLock { $0.now } }
    var minimumResolution: Duration { .zero }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        let id = state.withLock { state in
            state.nextID += 1
            return state.nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let outcome: Result<Void, any Error>? = state.withLock { state in
                    if state.cancelled.remove(id) != nil { return .failure(CancellationError()) }
                    if deadline <= state.now { return .success(()) }
                    state.sleepers.append(Sleeper(id: id, deadline: deadline, continuation: continuation))
                    return nil
                }
                if let outcome { continuation.resume(with: outcome) } else { slept.yield() }
            }
        } onCancel: {
            let sleeper: Sleeper? = state.withLock { state in
                guard let index = state.sleepers.firstIndex(where: { $0.id == id }) else {
                    state.cancelled.insert(id)
                    return nil
                }
                return state.sleepers.remove(at: index)
            }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Moves the clock on and wakes every sleeper whose deadline it reached.
    func advance(by duration: Duration) {
        let due: [Sleeper] = state.withLock { state in
            state.now = state.now.advanced(by: duration)
            let now = state.now
            let due = state.sleepers.filter { $0.deadline <= now }
            state.sleepers.removeAll { $0.deadline <= now }
            return due
        }
        for sleeper in due { sleeper.continuation.resume() }
    }
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
///
/// A wait that hangs (on a stage that should have committed) fails at the suite's time limit; the
/// stages' deadlines lie past it.
@MainActor @Suite(.timeLimit(.minutes(1)))
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

    /// A read-your-writes wait (an action that awaits its own echo) never waits on a script batch:
    /// a waiter for a sequence past a held event commits the stage at once (PL-main review, major 1).
    @Test func aWaiterPastAHeldEventCommitsTheStage() async {
        let store = Self.store()
        let scope = DaemonCommandScope()
        _ = store.openStage(for: scope, until: .now + .seconds(600))
        DaemonCommandScope.$current.withValue(scope) {
            store.intend(.renameTab(surface: 5, name: "batch"), transaction: .generate())
        }
        _ = store.apply(batch: [DaemonEventEnvelope(sequence: 1, event: Self.renamed(5, "batch", workspace: 1, pane: 10, screen: 100)),
                                DaemonEventEnvelope(sequence: 2, event: .titleChanged(surface: 21, title: "other"))])
        await store.applied(through: 2)
        #expect(store.stage == nil, "the waiter waited on the script's stage")
        #expect(store.appliedSequence >= 2)
        var ran = false
        store.whenApplied(.generate(), reaching: 2) { ran = true }
        #expect(ran)
    }

    /// Workspace list indexes do not commute: a held move of workspace 1 and a later move of
    /// workspace 2 apply in the daemon's order (PL-main review, major 2).
    @Test func heldAndLaterWorkspaceMovesKeepTheDaemonsOrder() {
        let store = Self.store()
        let scope = DaemonCommandScope()
        let stage = store.openStage(for: scope, until: .now + .seconds(600))
        let move = ClientTransactionID.generate()
        DaemonCommandScope.$current.withValue(scope) {
            store.intend(.moveWorkspace(key: WorkspaceKey(rawValue: "w1"), index: 1), transaction: move)
        }
        let tree = Self.tree()
        let first = tree.workspaces[0], second = tree.workspaces[1]
        // The daemon: workspace 1 moves to index 1 (order 2, 1; the echo of the script's move), then
        // workspace 2 moves to index 1 (order 1, 2).
        _ = store.apply(batch: [
            DaemonEventEnvelope(sequence: 1, event: .workspaceMoved(WorkspaceDelta(workspace: 1, index: 1, entity: first, workspaceRevision: 2,
                                                                                   clientTransactionID: move))),
            DaemonEventEnvelope(sequence: 2, event: .workspaceMoved(WorkspaceDelta(workspace: 2, index: 1, entity: second, workspaceRevision: 3))),
        ])
        stage.commit()
        #expect(store.workspaces.map(\.handle) == [1, 2], "the order is not the daemon's: \(store.workspaces.map(\.handle))")
    }

    /// A snapshot commits the whole stage, every joined batch's part (PL-main review, major 3).
    @Test func aSnapshotClosesAStageOfTwoBatches() {
        let store = Self.store()
        _ = store.openStage(for: DaemonCommandScope(), until: .now + .seconds(600))
        _ = store.openStage(for: DaemonCommandScope(), until: .now + .seconds(600))
        store.apply(snapshot: Self.tree())
        #expect(store.stage == nil)
    }

    /// The earliest deadline holds: a batch that joins with a later one never keeps the stage open
    /// longer (PL-main review, major 4). On a clock the test moves: only the first deadline passes.
    @Test func aLaterJoinDoesNotPushTheDeadlineBack() async throws {
        let store = Self.store()
        let clock = StageClock()
        var sleeps = clock.sleeps.makeAsyncIterator()
        let scope = DaemonCommandScope()
        let first = store.openStage(for: scope, until: clock.now.advanced(by: .seconds(10)), clock: clock)
        DaemonCommandScope.$current.withValue(scope) {
            store.intend(.renameTab(surface: 4, name: "batch"), transaction: .generate())
        }
        _ = store.openStage(for: DaemonCommandScope(), until: clock.now.advanced(by: .seconds(600)), clock: clock)
        _ = await sleeps.next() // the deadline sleeps on the clock
        clock.advance(by: .seconds(10))
        try await store.waitUntil("the stage commits at the first batch's deadline") { store.tab(surface: 4)?.name == "batch" }
        #expect(!first.stage.isOpen, "the second batch's later deadline kept the stage open")
    }

    /// A batch whose commit never comes does not hold the store: the stage commits at its deadline.
    @Test func aStageCommitsByItselfAtItsDeadline() async throws {
        let store = Self.store()
        let clock = StageClock()
        var sleeps = clock.sleeps.makeAsyncIterator()
        let scope = DaemonCommandScope()
        let batch = store.openStage(for: scope, until: clock.now.advanced(by: .seconds(5)), clock: clock)
        DaemonCommandScope.$current.withValue(scope) {
            store.intend(.renameTab(surface: 4, name: "batch"), transaction: .generate())
        }
        #expect(store.tab(surface: 4)?.name == nil)
        _ = await sleeps.next()
        clock.advance(by: .seconds(5))
        try await store.waitUntil("the stage commits at its deadline") { store.tab(surface: 4)?.name == "batch" }
        #expect(!batch.stage.isOpen, "the stage outlived its deadline")
    }

    // MARK: Review of d41d2d3a232..d2849fdd7c9 (lead cmux-ad)

    /// Review 1: a read-your-writes waiter that starts before its event arrives (the usual order: the
    /// command's reply, then its echo) never waits on the stage: the event it needs commits the stage.
    @Test func aWaiterThatStartsBeforeItsEventCommitsTheStage() async {
        let store = Self.store()
        let scope = DaemonCommandScope()
        _ = store.openStage(for: scope, until: .now + .seconds(600))
        DaemonCommandScope.$current.withValue(scope) {
            store.intend(.renameTab(surface: 5, name: "batch"), transaction: .generate())
        }
        var ran = false
        store.whenApplied(.generate(), reaching: 1) { ran = true }
        _ = store.apply(batch: [DaemonEventEnvelope(sequence: 1, event: Self.renamed(5, "batch", workspace: 1, pane: 10, screen: 100))])
        #expect(ran, "a whenApplied waiter for sequence 1 waited on the script's stage")
        #expect(store.stage == nil)

        // The async form, waiting before its event arrives.
        _ = store.openStage(for: scope, until: .now + .seconds(600))
        DaemonCommandScope.$current.withValue(scope) {
            store.intend(.renameTab(surface: 6, name: "batch"), transaction: .generate())
        }
        let through = Task { await store.applied(through: 2) }
        await Task.yield() // the main actor runs the task up to its wait
        #expect(store.sequenceWaits[2] == 1, "the wait did not start before its event")
        _ = store.apply(batch: [DaemonEventEnvelope(sequence: 2, event: Self.renamed(6, "batch", workspace: 1, pane: 10, screen: 100))])
        await through.value
        #expect(store.stage == nil, "applied(through:) waited on the script's stage")
        #expect(store.appliedSequence >= 2)
    }

    /// Review 2: workspace revisions do not commute: a held rename (revision 2) and a later change of
    /// another workspace (revision 3) apply in order at the commit, never revision 3 first (a resync).
    @Test func aHeldWorkspaceRevisionHoldsEveryLaterWorkspaceDelta() {
        let store = Self.store()
        let scope = DaemonCommandScope()
        let stage = store.openStage(for: scope, until: .now + .seconds(600))
        DaemonCommandScope.$current.withValue(scope) {
            store.intend(.renameWorkspace(key: WorkspaceKey(rawValue: "w1"), name: "renamed"), transaction: .generate())
        }
        let tree = Self.tree()
        var renamed = tree.workspaces[0]
        renamed.name = "renamed"
        let followup = store.apply(batch: [
            DaemonEventEnvelope(sequence: 1, event: .workspaceRenamed(WorkspaceDelta(workspace: 1, index: nil, entity: renamed, workspaceRevision: 2))),
            DaemonEventEnvelope(sequence: 2, event: .workspaceChanged(WorkspaceDelta(workspace: 2, index: nil, entity: tree.workspaces[1], workspaceRevision: 3))),
        ])
        #expect(followup != .resync, "revision 3 applied before the held revision 2")
        stage.commit()
        #expect(store.workspaceRevision == 3)
        #expect(store.workspace(handle: 1)?.name == "renamed")
    }

    /// Review 3: the events of a tab or a screen whose add the stage holds wait with it: a title set
    /// right after a held tab-added is not dropped, and a layout of a held new screen does not resync.
    @Test func eventsOfATabOrScreenTheStageHoldsWaitForIt() {
        let store = Self.store()
        let scope = DaemonCommandScope()
        let stage = store.openStage(for: scope, until: .now + .seconds(600))
        DaemonCommandScope.$current.withValue(scope) {
            store.intend(.renameTab(surface: 1, name: "batch"), transaction: .generate())
        }
        let added = TabSnapshot(surface: 9, title: "new")
        let screen = ScreenSnapshot(id: 300, active: false, activePane: 30, layout: .leaf(30),
                                    panes: [PaneSnapshot(id: 30, tabs: [TabSnapshot(surface: 31, title: "s")])])
        let followup = store.apply(batch: [
            DaemonEventEnvelope(sequence: 1, event: .tabAdded(TabDelta(workspace: 1, screen: 100, pane: 10, surface: 9, index: nil, entity: added))),
            DaemonEventEnvelope(sequence: 2, event: .titleChanged(surface: 9, title: "late")),
            DaemonEventEnvelope(sequence: 3, event: .screenAdded(ScreenDelta(workspace: 1, screen: 300, index: nil, entity: screen))),
            DaemonEventEnvelope(sequence: 4, event: .layoutChanged(screen: 300, layout: ScreenLayoutDelta(activePane: 30, layout: .leaf(30)),
                                                                   transaction: nil)),
        ])
        #expect(followup != .resync, "a held new screen's layout applied before the screen")
        stage.commit()
        #expect(store.tab(surface: 9)?.title == "late", "the title set after the held tab-added was dropped")
        #expect(store.screen(300) != nil)
    }

    /// Review 5: a new connection ends the stage: no held intent stays hidden, and no later commit
    /// moves the applied sequence back to the old connection's numbers.
    @Test func aNewConnectionEndsTheStage() {
        let store = Self.store()
        let scope = DaemonCommandScope()
        let stage = store.openStage(for: scope, until: .now + .seconds(600))
        DaemonCommandScope.$current.withValue(scope) {
            store.intend(.renameTab(surface: 7, name: "batch"), transaction: .generate())
        }
        _ = store.apply(batch: [DaemonEventEnvelope(sequence: 5, event: Self.renamed(7, "batch", workspace: 1, pane: 10, screen: 100))])
        store.beginConnection()
        #expect(store.stage == nil, "the stage outlived its connection")
        #expect(!store.intentLog.hasHeld)
        stage.commit()
        #expect(store.appliedSequence == 0, "a commit after the new connection moved the applied sequence to \(store.appliedSequence)")
    }

    /// Review 7: one batch's commit ends only its own part: a second commit from the same batch does
    /// not close a stage another batch still has open.
    @Test func aSecondCommitOfOneBatchKeepsTheOtherBatchsStage() {
        let store = Self.store()
        let first = store.openStage(for: DaemonCommandScope(), until: .now + .seconds(600))
        _ = store.openStage(for: DaemonCommandScope(), until: .now + .seconds(600))
        first.commit()
        first.commit()
        #expect(store.stage != nil, "the first batch's second commit closed the second batch's stage")
    }

    /// Review 2 of the fixes: a held event that needs a resync keeps the applied sequence below it at the
    /// commit, so no waiter runs on old records before the snapshot.
    @Test func aCommitThatNeedsAResyncDoesNotPassItsSequence() {
        let store = Self.store()
        let scope = DaemonCommandScope()
        let batch = store.openStage(for: scope, until: .now + .seconds(600))
        DaemonCommandScope.$current.withValue(scope) {
            store.intend(.renameTab(surface: 3, name: "batch"), transaction: .generate())
        }
        _ = store.apply(batch: [
            // Workspace 1's layout with no delta: only a snapshot carries it (a resync); held.
            DaemonEventEnvelope(sequence: 5, event: .layoutChanged(screen: 100, layout: nil, transaction: nil)),
            // Workspace 2: passes.
            DaemonEventEnvelope(sequence: 6, event: .titleChanged(surface: 21, title: "other")),
        ])
        #expect(store.appliedSequence < 5, "the applied sequence passed a held event")
        batch.commit()
        #expect(store.appliedSequence < 5, "the commit moved the applied sequence to \(store.appliedSequence), past an event that needs a resync")
    }
}
