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
                             canCreate: { true }, epoch: { 1 }, isLive: { true }, on: RepairTurns().work)
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

    @Test func theCauseIsTheLastEndedTerminals() {
        #expect(EmptiedWorkspaceCause.from([], workspace: key) == .tabClosed)
    }
}
