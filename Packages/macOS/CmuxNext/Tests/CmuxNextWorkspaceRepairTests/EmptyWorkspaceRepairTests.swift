import CmuxNextDaemon
@testable import CmuxNextWorkspaceRepair
import Testing

/// The explicit first-tab paths of the repair: one create per claim, a
/// failure kept with its reason, and a workspace emptied on purpose.
@MainActor struct EmptyWorkspaceRepairTests {
    struct Refused: Error {}
    final class Count { var value = 0 }

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

    @Test func theCauseIsTheLastEndedTerminals() {
        #expect(EmptiedWorkspaceCause.from([], workspace: key) == .tabClosed)
    }
}
