@testable import CmuxNextApp
@testable import CmuxNextCloud
import Foundation
import Testing

/// The owner side of a Cloud chat's hand-off turns (``CloudHandoffTurnOpener``): a prompt that
/// starts a turn names the turn the store made or began for it, never a turn that runs, waits for
/// the person or belongs to a closed hand-off or another machine.
@Suite(.serialized)
@MainActor
struct CloudHandoffTurnOpenerTests {
    private static let id = "ho_0123456789abcdef0123"

    private func view(turn: Int, status: String, state: String = "open", machine: String = "vm_a", session: String = "s-1") -> CloudHandoffTurn {
        CloudHandoffTurn(id: Self.id, sessionId: session, machine: machine, turn: turn, state: state, status: status)
    }

    /// Runs the opener against a scripted store: `made` answers the create, `begun` the turn's begin.
    private func open(_ made: CloudHandoffTurn, begun: CloudHandoffTurn? = nil) async throws -> (turn: Int?, begins: [Int]) {
        var begins: [Int] = []
        let opened = try await CloudHandoffTurnOpener.open(session: "s-1", machine: "vm_a", make: { _, _ in made }, begin: { _, after in
            begins.append(after)
            return try #require(begun)
        })
        return (opened?.number, begins)
    }

    @Test func aNewHandoffsFirstTurnIsNamed() async throws {
        let opened = try await open(view(turn: 1, status: "starting"))
        #expect(opened.turn == 1)
        #expect(opened.begins.isEmpty)
    }

    @Test func aTurnThatEndedBeginsTheNext() async throws {
        for status in ["done", "failed", "cancelled"] {
            let opened = try await open(view(turn: 3, status: status), begun: view(turn: 4, status: "starting"))
            #expect(opened.turn == 4, "\(status)")
            #expect(opened.begins == [3])
        }
    }

    @Test func aRunningTurnAClosedHandoffOrAnotherMachineNamesNone() async throws {
        #expect(try await open(view(turn: 2, status: "running")).turn == nil)
        #expect(try await open(view(turn: 2, status: "needs-you")).turn == nil)
        #expect(try await open(view(turn: 2, status: "done", state: "closed")).turn == nil)
        #expect(try await open(view(turn: 1, status: "starting", machine: "vm_b")).turn == nil)
    }

    @Test func aBeginAnotherDeviceWonIsNamedOnlyWhileItHasNotRun() async throws {
        var conflict = view(turn: 5, status: "starting")
        conflict.refusal = "handoff.turn_conflict"
        #expect(try await open(view(turn: 4, status: "done"), begun: conflict).turn == 5)
        #expect(try await open(view(turn: 4, status: "done"), begun: view(turn: 5, status: "running")).turn == nil)
    }

    @Test func theStoresHandoffIsReadAndItsMachineTokenIsNot() throws {
        let json: [String: Any] = ["id": Self.id, "sessionId": "s-1", "machine": "vm_a", "turn": 2, "state": "open", "status": "done", "version": 7]
        #expect(CloudHandoffTurn(json: json) == view(turn: 2, status: "done"))
        var bad = json
        bad["status"] = "paused"
        #expect(CloudHandoffTurn(json: bad) == nil)
        bad = json
        bad["turn"] = 0
        #expect(CloudHandoffTurn(json: bad) == nil)
    }

    @Test func onlyTheStoresOwnCodesReachThePage() {
        #expect(CloudHandoffTurnOpener.storeCode(CloudAPIError.http(status: 409, code: "handoff.closed", message: "closed")) == "handoff.closed")
        #expect(CloudHandoffTurnOpener.storeCode(CloudAPIError.http(status: 500, code: "Bad Thing <x>", message: nil)) == nil)
        #expect(CloudHandoffTurnOpener.storeCode(CloudAPIError.timedOut("/v1/handoffs")) == nil)
    }
}
