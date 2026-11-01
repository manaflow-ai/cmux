import CmuxNextDaemon
@testable import CmuxNextWorkspaceRepair
import Testing

/// The explicit first-tab paths of the repair: one create per claim, a
/// failure kept with its reason, and a workspace emptied on purpose.
@MainActor struct EmptyWorkspaceRepairTests {
    struct Refused: Error {}
    final class Count { var value = 0 }
    final class Holder { var repair: EmptyWorkspaceRepair? }

    let key = WorkspaceKey(rawValue: "w1")

    func repair(create: @escaping @MainActor (WorkspaceKey) async throws -> SurfaceID? = { _ in nil }) -> EmptyWorkspaceRepair {
        EmptyWorkspaceRepair(store: DaemonStore(), create: create, close: { _ in }, cause: { _ in .tabClosed },
                             canCreate: { true }, epoch: { 1 }, isLive: { true })
    }

    @Test func aRepeatedNewSendsOneCreate() async {
        let creates = Count()
        let repair = repair(create: { _ in creates.value += 1; return nil })
        repair.createFirstTab(key)
        repair.createFirstTab(key)
        #expect(repair.isSettling(key))
        for _ in 0..<20 where creates.value == 0 { await Task.yield() }
        #expect(creates.value == 1)
    }

    @Test func aFailedFirstTabKeepsItsReasonAndReleasesTheWorkspace() async {
        let repair = repair()
        await #expect(throws: Refused.self) {
            try await repair.fillFirstTab(key) { throw Refused() }
        }
        #expect(!repair.isSettling(key))
        #expect(repair.failure(key) == String(describing: Refused()))
    }

    @Test func aWorkspaceEmptiedOnPurposeSettlesUntilTheMoveEnds() {
        let repair = repair()
        repair.beginClosing(key)
        #expect(repair.states[key] == .closing)
        repair.endClosing(key)
        #expect(repair.states[key] == nil)
    }

    @Test func nestedPopulatesHoldUntilTheOutermostEnds() async {
        let repair = repair()
        await repair.populating(key) {
            await repair.populating(key) { #expect(repair.states[key] == .populating(2)) }
            #expect(repair.states[key] == .populating(1))
        }
        #expect(repair.states[key] == .awaitingPane)
    }

    /// #17632: a workspace whose last tab closed stays in the sidebar when the
    /// daemon refuses the close once; the next change this repair sees closes
    /// it again instead of leaving it (or refilling it with a terminal).
    @Test func aRefusedCloseIsRetriedOnTheNextChange() async throws {
        typealias Fixture = EmptyWorkspaceRepairCostTests
        let store = DaemonStore()
        store.apply(snapshot: DaemonTree(workspaceRevision: 10, workspaces: [Fixture.workspace(1), Fixture.workspace(2)]))
        let closes = Count(), creates = Count()
        let first = WorkspaceKey(rawValue: "ws-1")
        let repair = EmptyWorkspaceRepair(store: store, create: { _ in creates.value += 1; return nil },
                                          close: { key in
                                              guard key == first else { return }
                                              closes.value += 1
                                              if closes.value == 1 { throw Refused() }
                                          },
                                          cause: { _ in .tabClosed }, canCreate: { true }, epoch: { 1 }, isLive: { true })
        await Fixture.settle { repair.visited >= 2 }

        store.apply(try Fixture.paneClosed(workspace: 1))
        await Fixture.settle { closes.value == 1 && repair.states[first] == nil }
        #expect(closes.value == 1)

        // Any later change (here another workspace's last tab) retries it.
        store.apply(try Fixture.paneClosed(workspace: 2))
        await Fixture.settle { closes.value == 2 }
        #expect(closes.value == 2, "the refused close of ws-1 was never retried")
        #expect(creates.value == 0, "the emptied workspace was refilled instead of closed")
    }

    /// A refused close that spans a reconnect keeps the new connection's evidence: the workspace,
    /// shown with a pane again on the new connection, still closes when its last tab closes there.
    @Test func aRefusedCloseAcrossAReconnectKeepsTheNewConnectionsEvidence() async throws {
        typealias Fixture = EmptyWorkspaceRepairCostTests
        let store = DaemonStore()
        let tree = { (revision: UInt64) in DaemonTree(workspaceRevision: revision, workspaces: [Fixture.workspace(1)]) }
        store.apply(snapshot: tree(10))
        let closes = Count(), epoch = Count()
        epoch.value = 1
        let first = WorkspaceKey(rawValue: "ws-1")
        let holder = Holder()
        let repair = EmptyWorkspaceRepair(store: store, create: { _ in nil },
                                          close: { key in
                                              guard key == first else { return }
                                              closes.value += 1
                                              guard closes.value == 1 else { return }
                                              // The connection drops while the close is in flight; the
                                              // new one shows ws-1 with its pane, then the close fails.
                                              epoch.value = 2
                                              store.apply(snapshot: tree(11))
                                              // Wait for the reconnect snapshot to reach the repair before
                                              // returning the refused close. A fixed yield count can let the
                                              // close task clear its claim first, losing the new epoch's
                                              // evidence as a test scheduling artifact.
                                              await Fixture.settle { (holder.repair?.visited ?? 0) >= 3 }
                                              throw Refused()
                                          },
                                          cause: { _ in .tabClosed }, canCreate: { true }, epoch: { epoch.value },
                                          isLive: { true })
        holder.repair = repair
        await Fixture.settle { repair.visited >= 1 }

        store.apply(try Fixture.paneClosed(workspace: 1))
        await Fixture.settle { closes.value == 1 && repair.states[first] == nil }
        #expect(closes.value == 1)

        // Its last tab closes on the new connection: closed, not ignored on the old epoch.
        store.apply(try Fixture.paneClosed(workspace: 1))
        await Fixture.settle { closes.value == 2 }
        #expect(closes.value == 2, "the refused close restored the old connection's epoch over the new one's")
    }

    /// The workspace, repopulated on a new connection while its close is in flight, loses its last
    /// tab again before that close fails: the pane close was ignored (the close owned it), so the
    /// failed close queues it, and the next change closes it instead of leaving it empty.
    @Test func aWorkspaceEmptiedAgainDuringARefusedCloseIsClosedOnTheNextChange() async throws {
        typealias Fixture = EmptyWorkspaceRepairCostTests
        let store = DaemonStore()
        let tree = { (revision: UInt64) in
            DaemonTree(workspaceRevision: revision, workspaces: [Fixture.workspace(1), Fixture.workspace(2)])
        }
        store.apply(snapshot: tree(10))
        let closes = Count(), epoch = Count()
        epoch.value = 1
        let first = WorkspaceKey(rawValue: "ws-1")
        let holder = Holder()
        let repair = EmptyWorkspaceRepair(store: store, create: { _ in nil },
                                          close: { key in
                                              guard key == first else { return }
                                              closes.value += 1
                                              guard closes.value == 1 else { return }
                                              // A reconnect shows ws-1 with its pane, the pane closes
                                              // again, then the first close fails.
                                              epoch.value = 2
                                              store.apply(snapshot: tree(11))
                                              await Fixture.settle { (holder.repair?.visited ?? 0) >= 4 }
                                              store.apply(try Fixture.paneClosed(workspace: 1))
                                              await Fixture.settle { (holder.repair?.visited ?? 0) >= 5 }
                                              throw Refused()
                                          },
                                          cause: { _ in .tabClosed }, canCreate: { true }, epoch: { epoch.value },
                                          isLive: { true })
        holder.repair = repair
        await Fixture.settle { repair.visited >= 2 }

        store.apply(try Fixture.paneClosed(workspace: 1))
        await Fixture.settle { closes.value == 1 && repair.states[first] == nil }
        #expect(closes.value == 1)

        // Any later change (here ws-2's last tab) closes the stranded ws-1.
        store.apply(try Fixture.paneClosed(workspace: 2))
        await Fixture.settle { closes.value == 2 }
        #expect(closes.value == 2, "ws-1, emptied again during its refused close, was left open")
    }

    @Test func theCauseIsTheLastEndedTerminals() {
        #expect(EmptiedWorkspaceCause.from([], workspace: key) == .tabClosed)
    }
}
