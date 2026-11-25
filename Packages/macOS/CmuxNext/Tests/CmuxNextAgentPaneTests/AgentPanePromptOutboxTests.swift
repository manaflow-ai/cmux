// Leo, 2026-11-25: "Not sent ... (native.timed_out) Failed: 11017 ms after sending". The host's
// prompt outbox (AgentPanePromptRelay) forgot a resent prompt on any reply, a just-restarted
// acpmux's "not now" included, and never told the page. It now reads the whole reply, sends again
// after a "not now", and tells the page each step (`_cmux/prompt_resend`).
import Foundation
import Testing
import CmuxNextCompat
@testable import CmuxNextAgentPane

struct AgentPanePromptOutboxTests {
    @Test func replyReadsAcpmuxsRefusal() {
        let refusal: [String: Any] = ["jsonrpc": "2.0", "id": 7, "error": [
            "code": -32000, "message": "acpmux is starting",
            "data": ["code": "acpmux.not_ready", "reason": "starting", "origin": "daemon"],
        ]]
        let reply = AcpmuxRequestIds.Reply(refusal)
        #expect(reply == .init(ok: false, code: "acpmux.not_ready", reason: "starting", origin: "daemon",
                               message: "acpmux is starting"))
        #expect(AcpmuxRequestIds.Reply(["jsonrpc": "2.0", "id": 7, "result": [:] as [String: Any]]).ok)
        // A bare JSON-RPC code stands in when acpmux names none.
        #expect(AcpmuxRequestIds.Reply(["id": 7, "error": ["code": -32601, "message": "nope"]]).code == "-32601")
    }

    @Test func onlyANotNowIsSentAgain() {
        let notNow: [AcpmuxRequestIds.Reply] = [
            .init(ok: false, origin: "native"),
            .init(ok: false, code: "acpmux.not_ready"),
            .init(ok: false, reason: "session.busy"),
            .init(ok: false, code: "native.timed_out"),
            .init(ok: false, reason: "daemon_restarting"),
            .init(ok: false, code: "transport.unproven"),
        ]
        for reply in notNow { #expect(AgentPanePromptRelay.transient(reply), "\(reply)") }
        let no: [AcpmuxRequestIds.Reply] = [
            .init(ok: true),
            .init(ok: false, code: "session.not_found", reason: "session.not_found"),
            .init(ok: false, code: "remote.local_claude_session"),
            .init(ok: false, code: "-32602"),
        ]
        for reply in no { #expect(!AgentPanePromptRelay.transient(reply), "\(reply)") }
    }

    @Test func backoffGrowsAndStopsAtThirtySeconds() {
        #expect(AgentPanePromptRelay.backoff(attempt: 0) == .seconds(1))
        #expect(AgentPanePromptRelay.backoff(attempt: 1) == .seconds(2))
        #expect(AgentPanePromptRelay.backoff(attempt: 4) == .seconds(16))
        #expect(AgentPanePromptRelay.backoff(attempt: 5) == .seconds(30))
        #expect(AgentPanePromptRelay.backoff(attempt: 500) == .seconds(30))
        #expect(AgentPanePromptRelay.backoff(attempt: -1) == .seconds(1))
    }

    @Test func aHostRequestsWholeReplyReachesItsHandlerAndNeverThePage() {
        let ids = AcpmuxRequestIds()
        let id = ids.hostID()
        let got = Mutex<AcpmuxRequestIds.Reply?>(nil)
        ids.whenReply(id) { reply in got.withLock { $0 = reply } }
        let text = #"{"jsonrpc":"2.0","id":\#(id),"error":{"code":-32000,"message":"busy","data":{"code":"session.busy"}}}"#
        guard case .drop = ids.toPage(text) else {
            Issue.record("a host request's reply reached the page")
            return
        }
        #expect(got.withLock { $0 } == .init(ok: false, code: "session.busy", message: "busy"))
        // Once: a second reply with the id finds no handler.
        got.withLock { $0 = nil }
        _ = ids.toPage(text)
        #expect(got.withLock { $0 } == nil)
    }

    @Test func aCancelledHostRequestNeverHearsItsReply() {
        let ids = AcpmuxRequestIds()
        let id = ids.hostID()
        let got = Mutex(false)
        ids.whenReply(id) { _ in got.withLock { $0 = true } }
        ids.cancel(id)
        _ = ids.toPage(#"{"jsonrpc":"2.0","id":\#(id),"result":{}}"#)
        #expect(!got.withLock { $0 })
    }
}
