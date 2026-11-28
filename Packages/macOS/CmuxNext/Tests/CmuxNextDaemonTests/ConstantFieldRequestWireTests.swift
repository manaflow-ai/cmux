import Foundation
import Testing
@testable import CmuxNextDaemon

/// The exact request lines of the requests that send a fixed value: `create-terminal {detached: true, keep:
/// true}` (`CreateDetachedTerminalRequest`) always, `new-pane-right {side: "left"}` (`NewColumnRequest.left`)
/// when asked; both go to a daemon whatever it advertises. These bytes are the contract the generated types
/// (swift_app field `constant`) keep with the hand-written ones they replaced.
struct ConstantFieldRequestWireTests {
    private func line(_ request: some DaemonRequest) throws -> String {
        String(decoding: try WireCoding.encodeRequest(request, id: 7), as: UTF8.self)
    }

    @Test func aDetachedTerminalAlwaysSendsDetachedAndKeep() throws {
        #expect(try line(CreateDetachedTerminalRequest(mutation: nil))
            == #"{"cmd":"create-terminal","detached":true,"id":7,"keep":true}"#)
        #expect(CreateDetachedTerminalRequest.requiredCapability == nil)
    }

    @Test func aDetachedTerminalSendsEveryFieldItSets() throws {
        let request = CreateDetachedTerminalRequest(
            cwd: "/tmp", size: CellSize(cols: 80, rows: 24), terminalID: TerminalID(rawValue: "t1"), env: ["lang": "c"],
            mutation: MutationIdentity(origin: "app", mutationID: "m1"))
        #expect(try line(request)
            == #"{"cmd":"create-terminal","cols":80,"cwd":"/tmp","detached":true,"env":{"lang":"c"},"id":7,"keep":true,"mutation_id":"m1","origin":"app","rows":24,"terminal_id":"t1"}"#)
    }

    @Test func aLeftColumnSendsItsSideAndARightOneDoesNot() throws {
        #expect(try line(NewColumnRequest(pane: 3, left: true)) == #"{"cmd":"new-pane-right","id":7,"pane":3,"side":"left"}"#)
        #expect(try line(NewColumnRequest(pane: 3)) == #"{"cmd":"new-pane-right","id":7,"pane":3}"#)
        #expect(NewColumnRequest.requiredCapability == nil)
    }
}
