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

    /// The frame the relay sends for `params` on `method`, after its checks.
    private static func sent(_ method: String, _ params: [String: Any]) throws -> [String: Any] {
        guard case .frame(_, let box) = AgentPaneTransport.checkOne(try text(method, params), snapshot()),
              let encoded = box.encoded(id: nil) else {
            Issue.record("the relay refused \(method) \(params.keys.sorted())")
            return [:]
        }
        let object = try #require(JSONSerialization.jsonObject(with: Data(encoded.utf8)) as? [String: Any])
        return try #require(object["params"] as? [String: Any])
    }

    /// A key the relay does not know is dropped, not refused (P0): a newer page keeps its chats.
    /// cmux#42185 (`settled`), #42460 (`hold`) and #46563 (`initialize` `peerRowBatches`) each
    /// refused every chat's open over one such key.
    @Test func anAttachWithAKeyTheRelayDoesNotKnowGoesWithoutIt() throws {
        let params = try Self.sent("_acpmux/attach", ["sessionId": "s", "limit": 400, "pinned": true])
        #expect(params["pinned"] == nil)
        #expect(params["sessionId"] as? String == "s")
        #expect(params["limit"] as? Int == 400)
    }

    @Test func aStartWithAnAcpmuxKeyTheRelayDoesNotKnowGoesWithoutIt() throws {
        let params: [String: Any] = [
            "cwd": "/tmp", "mcpServers": [Any](),
            "_meta": ["acpmux": ["harness": "claude", "launchProfile": "fast"]],
        ]
        let sent = try Self.sent("session/new", params)
        let acpmux = try #require((sent["_meta"] as? [String: Any])?["acpmux"] as? [String: Any])
        #expect(acpmux["launchProfile"] == nil)
        #expect(acpmux["harness"] as? String == "claude")
    }

    @Test func theStripNamesWhatItDropped() throws {
        let object: [String: Any] = ["method": "initialize", "params": [
            "protocolVersion": 1, "futureTopLevel": 1,
            "_meta": ["acpmux": ["someFutureFlag": true], "otherVendor": [String: Any]()],
        ]]
        let strip = try #require(AcpmuxPaneMethods.strippingUnknownParams(object, modeFields: nil))
        #expect(strip.dropped == ["_meta.acpmux.someFutureFlag", "_meta.otherVendor", "futureTopLevel"])
        #expect(AcpmuxPaneMethods.paramsRuleViolation(strip.object, modeFields: nil) == nil)
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
