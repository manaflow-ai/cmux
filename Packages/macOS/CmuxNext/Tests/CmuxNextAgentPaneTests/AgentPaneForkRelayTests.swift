import Foundation
import Testing
@testable import CmuxNextAgentPane

/// Fork Conversation (the palette's step, the chat's right-click menu, its shortcut) forks a
/// working chat as it is now: the page sends `acp.session.fork {sessionId, live: true}`
/// (`direct.ts` `fork("live")`), which acpmux serves (`server/fork_through.rs`). The host's
/// params rule let only `throughSeq` through, so every fork of a working chat was refused with
/// `transport.intent_invalid` and no fork opened (NIGHTLY 2026-10-29, "it actually failed").
@Suite
struct AgentPaneForkRelayTests {
    static func object(_ params: String) -> [String: Any]? {
        let frame = #"{"jsonrpc":"2.0","id":7,"method":"acp.session.fork","params":\#(params)}"#
        return (try? JSONSerialization.jsonObject(with: Data(frame.utf8))) as? [String: Any]
    }

    @Test(arguments: [
        #"{"sessionId":"s","live":true}"#,
        #"{"sessionId":"s","throughSeq":12}"#,
    ])
    func thePagesForkFramesPassTheParamsRule(_ params: String) {
        #expect(!AcpmuxPaneMethods.breaksParamsRule(Self.object(params), modeFields: []), "\(params)")
    }

    @Test(arguments: [
        #"{"sessionId":"s","live":true,"_meta":{"acpmux":{"via":"web"}}}"#,
        #"{"sessionId":"s","live":true,"cwd":"/"}"#,
    ])
    func aForkCarriesNothingElse(_ params: String) {
        #expect(AcpmuxPaneMethods.breaksParamsRule(Self.object(params), modeFields: []), "\(params)")
    }
}
