import CmuxNextMobile
import Foundation
import Testing

struct AcpmuxLanePolicyTests {
    let policy = AcpmuxLanePolicy()

    func verdict(_ json: String) -> DaemonLanePolicy.Verdict { policy.evaluate(Data(json.utf8)) }

    @Test func conversationMethodsPass() {
        for m in ["session/prompt", "session/new", "_acpmux/attach", "_acpmux/dequeue", "_acpmux/retry", "_acpmux/future_method"] {
            #expect(verdict(#"{"jsonrpc":"2.0","id":1,"method":"\#(m)","params":{}}"#) == .forward, "\(m)")
        }
        #expect(verdict(#"{"jsonrpc":"2.0","id":1,"method":"_acpmux/defaults","params":{}}"#) == .forward)
    }

    @Test func daemonAdminIsRefusedWithAJSONRPCError() throws {
        for m in ["_acpmux/shutdown", "_acpmux/peer_add", "_acpmux/import", "_acpmux/export", "_acpmux/reload_config"] {
            guard case let .refuse(data) = verdict(#"{"jsonrpc":"2.0","id":7,"method":"\#(m)","params":{}}"#) else {
                Issue.record("\(m) was forwarded"); continue
            }
            let reply = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(reply["id"] as? Int == 7)
            #expect((reply["error"] as? [String: Any])?["code"] as? Int == -32001)
        }
        guard case .refuse = verdict(#"{"jsonrpc":"2.0","id":2,"method":"_acpmux/defaults","params":{"set":{"model":"x"}}}"#) else {
            Issue.record("defaults set was forwarded"); return
        }
    }
}
