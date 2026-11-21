import Foundation
import Testing
@testable import CmuxNextAgentPane

/// A frame the relay refuses under its params rule says which rule part it broke (cmux#44964). On
/// 2026-11-12 every chat failed to start after acpmux restarted: the relay refused the page's attach
/// for a key it did not know (`settled`, cmux#42185; `hold` later, cmux#42460), and neither the
/// card nor the app's log named the key. The refusal the page receives now carries it in
/// `data.detail`, which the failed card shows under Details; a param's value never goes there.
@Suite
struct AcpmuxPaneParamsRefusalCauseTests {
    private static func snapshot() -> AgentPaneTransport.Snapshot {
        let sessions = AcpmuxPaneSessions()
        sessions.add("s")
        return AgentPaneTransport.Snapshot(isFirst: false, localAppToken: nil, socketPath: nil,
                                            modeFields: ["permissionMode"], sessions: sessions,
                                            options: AcpmuxPermissionOptions(), remoteWire: false)
    }

    private static func text(_ method: String, _ params: [String: Any]) throws -> String {
        let frame: [String: Any] = ["jsonrpc": "2.0", "id": 7, "method": method, "params": params]
        return String(decoding: try JSONSerialization.data(withJSONObject: frame), as: UTF8.self)
    }

    /// The refusal the page receives for `params` on `method`: its JSON-RPC `error.data`.
    private static func refusalData(_ method: String, _ params: [String: Any]) throws -> [String: Any] {
        guard case .refuse(let decision, _) = AgentPaneTransport.checkOne(try text(method, params), snapshot()),
              case .refuse(let error, let refusedMethod, let requestID?, let detail) = decision else {
            Issue.record("the relay passed \(method) \(params.keys.sorted())")
            return [:]
        }
        let frame = AcpmuxPaneMethods.refusal(requestID: requestID, error: error, method: refusedMethod, detail: detail)
        let object = try #require(JSONSerialization.jsonObject(with: Data(frame.utf8)) as? [String: Any])
        let reply = try #require(object["error"] as? [String: Any])
        return try #require(reply["data"] as? [String: Any])
    }

    @Test func anAttachWithAKeyTheRelayDoesNotKnowNamesTheKey() throws {
        let data = try Self.refusalData("_acpmux/attach", ["sessionId": "s", "limit": 400, "pinned": true])
        #expect(data["code"] as? String == "transport.intent_invalid")
        #expect(data["method"] as? String == "_acpmux/attach")
        #expect(data["detail"] as? String == #"unknown param "pinned""#)
    }

    @Test func aStartWithAnAcpmuxKeyTheRelayDoesNotKnowNamesTheKey() throws {
        let params: [String: Any] = [
            "cwd": "/tmp", "mcpServers": [Any](),
            "_meta": ["acpmux": ["harness": "claude", "launchProfile": "fast"]],
        ]
        let data = try Self.refusalData("session/new", params)
        #expect(data["method"] as? String == "session/new")
        #expect(data["detail"] as? String == #"unknown _meta.acpmux key "launchProfile""#)
    }

    @Test func aModeFieldOutsideTheSettingMethodsIsNamedAsOne() throws {
        let params: [String: Any] = ["cwd": "/tmp", "mcpServers": [Any](), "_meta": ["acpmux": ["permissionMode": "bypassPermissions"]]]
        let data = try Self.refusalData("session/new", params)
        #expect(data["detail"] as? String == #"mode field "permissionMode" in _meta.acpmux"#)
    }

    @Test func theCauseNeverCarriesAParamValue() throws {
        let params: [String: Any] = ["cwd": "/tmp", "mcpServers": [Any](), "_meta": ["acpmux": ["harness": "claude", "model": "--dangerously-skip-permissions"]]]
        let data = try Self.refusalData("session/new", params)
        let detail = try #require(data["detail"] as? String)
        #expect(detail == "_meta.acpmux.model is not a model id")
        #expect(!detail.contains("dangerously"))
    }

    @Test func aFrameThePageSendsStillPasses() throws {
        let params: [String: Any] = ["cwd": "/tmp", "mcpServers": [Any](), "_meta": ["acpmux": ["harness": "claude"]]]
        #expect(AcpmuxPaneMethods.paramsRuleViolation(["method": "session/new", "params": params], modeFields: ["permissionMode"]) == nil)
    }
}
