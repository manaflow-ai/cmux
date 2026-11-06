import Foundation
import Testing
@testable import CmuxNextAgentPane

/// Fork Conversation's Cancel (Leo, 2026-11-06: "i shuold be able to cancel a fork probably")
/// sends `_acpmux/kill {sessionId, purge, cancelFork}`: the params rule lets it through, so the
/// fork's transcript copy goes with it, and still refuses a key the pane never sends.
@Suite
struct AcpmuxPaneForkCancelParamsTests {
    private static func kill(_ params: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": 1, "method": "_acpmux/kill", "params": params]
    }

    @Test func cancelOnAPendingForkPassesTheParamsRule() {
        let cancel = Self.kill(["sessionId": "fork-1", "purge": true, "cancelFork": true])
        #expect(!AcpmuxPaneMethods.breaksParamsRule(cancel, modeFields: nil))
    }

    @Test func anotherKeyOnKillIsStillRefused() {
        let other = Self.kill(["sessionId": "fork-1", "purge": true, "ifIdle": true])
        #expect(AcpmuxPaneMethods.breaksParamsRule(other, modeFields: nil))
    }
}
