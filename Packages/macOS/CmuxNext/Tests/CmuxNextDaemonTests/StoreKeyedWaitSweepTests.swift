@testable import CmuxNextDaemon
import Testing

/// The daemon store's waits of file group p06-scheduler-339 (recipe R-wait): the first pane of a workspace made by
/// key, a reopened workspace and the session state's first answer are keyed waits (StoreWaiters), not
/// ObservationStreams over the store. A waiter reads its condition only when its key changes, and resumes in the
/// apply that satisfies it.
@MainActor @Suite(.timeLimit(.minutes(1))) struct StoreKeyedWaitSweepTests {
    /// A timeout no test reaches.
    private static let never: Duration = .seconds(3_600)
    private static let key = WorkspaceKey(rawValue: "made-by-key")

    /// Workspace 1, made under ``key``, whose one screen has no pane yet.
    private static func emptyKeyedWorkspace() -> DaemonTree {
        DaemonTree(workspaceRevision: 1, workspaces: [
            WorkspaceSnapshot(id: 1, key: key, name: "w1", screens: [ScreenSnapshot(id: 2, layout: .leaf(9), panes: [])]),
        ])
    }

    @Test func aFirstPaneWaitResumesInTheApplyThatGivesItsWorkspaceAPane() async throws {
        let store = DaemonStore()
        store.apply(snapshot: Self.emptyKeyedWorkspace())
        let wait = Task { await store.firstPane(mirroring: Self.key, timeout: Self.never) }
        await store.waiters.untilPending(1)
        let before = store.waiters.evaluations

        _ = store.apply(.titleChanged(surface: 77, title: "another surface"))
        #expect(store.waiters.evaluations == before, "a change of no workspace read the first-pane waiter's condition")

        _ = store.apply(batch: [DaemonEventEnvelope(sequence: 1, event: .paneAdded(PaneDelta(
            workspace: 1, screen: 2, pane: 9, index: 0, entity: PaneSnapshot(id: 9, tabs: [TabSnapshot(surface: 7)]),
            clientTransactionID: nil)))])
        #expect(store.waiters.pendingCount == 0, "the pane's own apply did not resume the waiter")
        let pane = try #require(await wait.value)
        #expect(pane.handle == 9)
    }

    @Test func aFirstPaneOfAListedWorkspaceReturnsAtOnce() async throws {
        let store = DaemonStore()
        store.apply(snapshot: DaemonTree(workspaceRevision: 1, workspaces: [
            WorkspaceSnapshot(id: 1, key: Self.key, name: "w1", screens: [
                ScreenSnapshot(id: 2, layout: .leaf(9), panes: [PaneSnapshot(id: 9, tabs: [TabSnapshot(surface: 7)])]),
            ]),
        ]))
        let pane = try #require(await store.firstPane(mirroring: Self.key, timeout: Self.never))
        #expect(pane.handle == 9)
        #expect(store.waiters.pendingCount == 0)
    }

    @Test func aSessionStateWaitResumesWhenTheStreamAnswers() async {
        let store = DaemonStore()
        #expect(!store.session.known)
        let wait = Task { await store.sessionStateResolved() }
        await store.waiters.untilPending(1)
        _ = store.apply(.sessionState(.ended(reason: "gap")))
        #expect(store.session.known)
        #expect(store.waiters.pendingCount == 0, "the session stream's answer did not resume the wait")
        await wait.value
    }

    /// A box the waiting task sets when the wait returns.
    @MainActor private final class Returned {
        var value = false
    }

    /// The session-state wait has no time limit. Its keyed wait's bound passing on an
    /// unchanged connection with the session still unknown files the wait again; it returns only when the stream
    /// answers (or the connection changes).
    @Test func aSessionStateWaitDoesNotReturnWhenItsKeyedBoundPasses() async {
        let rig = DeadlineRig()
        let store = DaemonStore(waitDeadlines: rig.queue)
        let returned = Returned()
        let wait = Task {
            await store.sessionStateResolved()
            returned.value = true
        }
        await store.waiters.untilPending(1)
        let filed = store.waiters.evaluations

        rig.advance(by: DaemonStore.sessionStateWaitBound + .seconds(1))
        #expect(store.waiters.pendingCount == 0, "the keyed wait's bound did not pass")
        await store.waiters.untilPending(1)
        #expect(store.waiters.evaluations == filed + 1, "the wait did not file again after its bound")
        #expect(!returned.value, "the wait returned with the session unknown on an unchanged connection")
        #expect(!store.session.known)

        _ = store.apply(.sessionState(.ended(reason: "gap")))
        await wait.value
        #expect(returned.value)
    }
}
