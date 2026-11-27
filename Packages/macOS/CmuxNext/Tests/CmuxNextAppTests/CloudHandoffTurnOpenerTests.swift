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

    /// Runs the opener against a scripted store: `made` answers the create, `begun` each begin in turn.
    private func open(_ made: CloudHandoffTurn, begun: [CloudHandoffTurn] = []) async throws -> (opened: CloudHandoffTurnOpener.Opened, begins: [Int]) {
        var begins: [Int] = []
        let opened = try await CloudHandoffTurnOpener.open(session: "s-1", machine: "vm_a", make: { _, _ in made }, begin: { _, after in
            begins.append(after)
            return try #require(begun.count >= begins.count ? begun[begins.count - 1] : nil)
        })
        return (opened, begins)
    }

    @Test func aNewHandoffsFirstTurnIsNamed() async throws {
        let opened = try await open(view(turn: 1, status: "starting"))
        #expect(opened.opened == .turn(id: Self.id, number: 1))
        #expect(opened.begins.isEmpty)
    }

    @Test func aTurnThatEndedBeginsTheNext() async throws {
        for status in ["done", "failed", "cancelled"] {
            let opened = try await open(view(turn: 3, status: status), begun: [view(turn: 4, status: "starting")])
            #expect(opened.opened == .turn(id: Self.id, number: 4), "\(status)")
            #expect(opened.begins == [3])
        }
    }

    @Test func aHandoffClosedBetweenCreateAndBeginPropagatesItsRefusal() async throws {
        var closed = view(turn: 3, status: "done", state: "closed")
        let opened = try await open(view(turn: 3, status: "done"), begun: [closed])
        #expect(opened.opened == .refused("handoff.closed"))
        #expect(opened.begins == [3])
    }

    @Test func aRunningTurnAClosedHandoffOrAnotherMachineNamesNoneAndSaysWhy() async throws {
        #expect(try await open(view(turn: 2, status: "running")).opened == .refused("handoff.turn_running"))
        #expect(try await open(view(turn: 2, status: "needs-you")).opened == .refused("handoff.turn_running"))
        #expect(try await open(view(turn: 2, status: "done", state: "closed")).opened == .refused("handoff.closed"))
        #expect(try await open(view(turn: 1, status: "starting", machine: "vm_b")).opened == .refused("handoff.conflict"))
        var conflict = view(turn: 2, status: "done")
        conflict.refusal = "handoff.conflict"
        #expect(try await open(conflict).opened == .refused("handoff.conflict"))
    }

    @Test func aBeginAnotherDeviceWonIsNamedOnlyWhileItHasNotRun() async throws {
        var conflict = view(turn: 5, status: "starting")
        conflict.refusal = "handoff.turn_conflict"
        #expect(try await open(view(turn: 4, status: "done"), begun: [conflict]).opened == .turn(id: Self.id, number: 5))
        #expect(try await open(view(turn: 4, status: "done"), begun: [view(turn: 5, status: "running")]).opened == .refused("handoff.turn_running"))
    }

    @Test func aTurnAnotherDeviceBeganAndFinishedBeginsTheOneAfter() async throws {
        var ended = view(turn: 5, status: "done")
        ended.refusal = "handoff.turn_conflict"
        let opened = try await open(view(turn: 4, status: "done"), begun: [ended, view(turn: 6, status: "starting")])
        #expect(opened.opened == .turn(id: Self.id, number: 6))
        #expect(opened.begins == [4, 5])
        // Two begins other devices won and finished, then a third that makes the turn: it is named.
        var five = view(turn: 5, status: "done"), six = view(turn: 6, status: "done")
        five.refusal = "handoff.turn_conflict"
        six.refusal = "handoff.turn_conflict"
        let third = try await open(view(turn: 4, status: "done"), begun: [five, six, view(turn: 7, status: "starting")])
        #expect(third.opened == .turn(id: Self.id, number: 7))
        #expect(third.begins == [4, 5, 6])
        // A begin that answers no newer turn names none.
        #expect(try await open(view(turn: 4, status: "done"), begun: [view(turn: 4, status: "done")]).opened == .refused("handoff.turn_conflict"))
    }

    /// After a team switch the previous team's machines stay in the store until this team's list
    /// lands: no hand-off is offered (the handshake's `cloudHandoffs`) or made for one of them. The
    /// runner answers the refusal before any store call, so nothing is posted.
    @Test func aMachineListNotLoadedForTheAccountNowOpensNoTurn() {
        #expect(CloudHandoffTurnOpener.refusal(cloudAllowed: true, labs: true, signedIn: true, loadedCurrent: true) == nil)
        #expect(CloudHandoffTurnOpener.refusal(cloudAllowed: true, labs: true, signedIn: true, loadedCurrent: false) == "machines_unread")
        #expect(CloudHandoffTurnOpener.refusal(cloudAllowed: true, labs: true, signedIn: false, loadedCurrent: false) == "not_signed_in")
        #expect(CloudHandoffTurnOpener.refusal(cloudAllowed: true, labs: false, signedIn: true, loadedCurrent: true) == "labs_off")
        #expect(CloudHandoffTurnOpener.refusal(cloudAllowed: false, labs: true, signedIn: true, loadedCurrent: true) == "cloud_disabled")
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

    @Test func onlyTheSessionRecordedOnThePanesTabNamesTurns() {
        #expect(CloudHandoffTurnOpener.ownsSession(recorded: "s1", asked: "s1"))
        #expect(!CloudHandoffTurnOpener.ownsSession(recorded: "s1", asked: "s2"))
        // A new chat whose session is not bound to its tab yet names no turn for any session.
        #expect(!CloudHandoffTurnOpener.ownsSession(recorded: nil, asked: "s1"))
        #expect(!CloudHandoffTurnOpener.ownsSession(recorded: "", asked: ""))
    }
}
