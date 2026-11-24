import Foundation
import Testing
@testable import CmuxNextAgentPane

/// The handshake fails safe. cmux#46563 added `_meta.acpmux.peerRowBatches` to the page's
/// `initialize` and not to the relay's params rule; the relay refused every initialize as
/// `transport.intent_invalid` (`unknown _meta.acpmux key`), and no GUI chat connected in Leo's
/// NIGHTLY for about 7 h (737+ refusals, 2026-11-21). A newer page's capability opt-in now goes
/// without that key, so the daemon answers with its default behaviour; everything else the
/// params rule refuses on the handshake, and every key on every other method, stays refused.
@Suite
struct AcpmuxPaneInitializeFailSafeTests {
    private static let hostToken = String(repeating: "a", count: 64)

    private static func snapshot(first: Bool = true) -> AgentPaneTransport.Snapshot {
        let sessions = AcpmuxPaneSessions()
        sessions.add("s")
        return AgentPaneTransport.Snapshot(isFirst: first, localAppToken: first ? hostToken : nil, socketPath: nil,
                                            modeFields: ["permissionMode"], sessions: sessions,
                                            options: AcpmuxPermissionOptions(), remoteWire: false)
    }

    private static func text(_ method: String, _ params: [String: Any]) throws -> String {
        let frame: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": method, "params": params]
        return String(decoding: try JSONSerialization.data(withJSONObject: frame), as: UTF8.self)
    }

    private static func initialize(_ meta: [String: Any]) throws -> String {
        var params = try AcpmuxPaneInitializeParamsContractTests.contract()
        params["_meta"] = meta
        return try text("initialize", params)
    }

    /// The frame the relay forwards to the daemon, or nil when it refused it.
    private static func forwarded(_ text: String, first: Bool = true) throws -> [String: Any]? {
        guard case .frame(_, let box) = AgentPaneTransport.checkOne(text, snapshot(first: first)) else { return nil }
        let encoded = try #require(box.encoded(id: 1))
        return try #require(JSONSerialization.jsonObject(with: Data(encoded.utf8)) as? [String: Any])
    }

    /// The rule part the relay named when it refused `text`, or nil when it forwarded it.
    private static func refusal(_ text: String, first: Bool = true) -> String? {
        guard case .refuse(let decision, _) = AgentPaneTransport.checkOne(text, snapshot(first: first)),
              case .refuse(_, _, _, let detail) = decision else { return nil }
        return detail ?? "refused"
    }

    private static func acpmux(_ frame: [String: Any]?) -> [String: Any]? {
        ((frame?["params"] as? [String: Any])?["_meta"] as? [String: Any])?["acpmux"] as? [String: Any]
    }

    @Test func anInitializeWithAnOptInTheRelayDoesNotKnowGoesWithoutIt() throws {
        let text = try Self.initialize(["acpmux": ["peerRowBatches": true, "someFutureFlag": true]])
        let frame = try #require(try Self.forwarded(text), "the relay refused: \(Self.refusal(text) ?? "-")")
        let acpmux = try #require(Self.acpmux(frame))
        #expect(acpmux["someFutureFlag"] == nil)
        #expect(acpmux["peerRowBatches"] as? Bool == true)
        #expect(acpmux["localAppToken"] as? String == Self.hostToken)
        #expect(Set(acpmux.keys) == ["peerRowBatches", "localAppToken"])
        #expect(frame["method"] as? String == "initialize")
    }

    @Test func anInitializeWithOnlyUnknownOptInsStillConnects() throws {
        let text = try Self.initialize(["acpmux": ["rowsV9": 2, "other": ["nested": true]]])
        let acpmux = try #require(Self.acpmux(try Self.forwarded(text)))
        #expect(Set(acpmux.keys) == ["localAppToken"])
    }

    @Test func aModeFieldInTheInitializeAcpmuxIsStillRefused() throws {
        let text = try Self.initialize(["acpmux": ["peerRowBatches": true, "permissionMode": "bypassPermissions"]])
        #expect(Self.refusal(text) == #"mode field "permissionMode" in _meta.acpmux"#)
    }

    @Test func theLocalAppTokenOrPersonKeyFromThePageIsStillRefused() throws {
        for key in ["localAppToken", "personKey"] {
            let text = try Self.initialize(["acpmux": ["peerRowBatches": true, key: String(repeating: "b", count: 64)]])
            #expect(Self.refusal(text) == "unknown _meta.acpmux key \"\(key)\"", "\(key)")
        }
    }

    @Test func anInitializesUnknownTopLevelParamOrMetaSiblingIsStillRefused() throws {
        var params = try AcpmuxPaneInitializeParamsContractTests.contract()
        params["futureParam"] = true
        #expect(Self.refusal(try Self.text("initialize", params)) == #"unknown param "futureParam""#)
        let sibling = try Self.initialize(["acpmux": ["peerRowBatches": true], "other": true])
        #expect(Self.refusal(sibling) == #"unknown _meta key "other""#)
        let notObject = try Self.initialize(["acpmux": "peerRowBatches"])
        #expect(Self.refusal(notObject) == "_meta.acpmux is not an object")
    }

    @Test func unknownKeysOnOtherMethodsAreStillRefused() throws {
        let start: [String: Any] = ["cwd": "/tmp", "mcpServers": [Any](), "_meta": ["acpmux": ["harness": "claude", "someFutureFlag": true]]]
        #expect(Self.refusal(try Self.text("session/new", start), first: false) == #"unknown _meta.acpmux key "someFutureFlag""#)
        let prompt: [String: Any] = ["sessionId": "s", "prompt": [Any](), "_meta": ["acpmux": ["promptId": "p", "someFutureFlag": true]]]
        #expect(Self.refusal(try Self.text("session/prompt", prompt), first: false) == #"unknown _meta.acpmux key "someFutureFlag""#)
        let attach: [String: Any] = ["sessionId": "s", "someFutureFlag": true]
        #expect(Self.refusal(try Self.text("_acpmux/attach", attach), first: false) == #"unknown param "someFutureFlag""#)
    }

    @Test func theInitializeThePageSendsGoesUnchangedButForTheToken() throws {
        let params = try AcpmuxPaneInitializeParamsContractTests.contract()
        let acpmux = try #require(Self.acpmux(try Self.forwarded(try Self.text("initialize", params))))
        #expect(Set(acpmux.keys) == ["peerRowBatches", "localAppToken"])
    }
}
