import Foundation
import Testing
@testable import CmuxNextAgentPane

/// Context must pass the page's actual transport gate before RemoteAcpmuxWire
/// routes it to the session attachment. Never accept a page-supplied folder.
struct AgentPaneTransportContextTests {
    private static func snapshot(first: Bool = false) -> AgentPaneTransport.Snapshot {
        let sessions = AcpmuxPaneSessions()
        sessions.add("own")
        return AgentPaneTransport.Snapshot(isFirst: first, localAppToken: nil, socketPath: nil,
                                            modeFields: nil, sessions: sessions,
                                            options: AcpmuxPermissionOptions(), remoteWire: true)
    }

    private static func text(_ method: String, _ params: [String: Any]) throws -> String {
        let frame: [String: Any] = ["jsonrpc": "2.0", "id": 7, "method": method, "params": params]
        return String(decoding: try JSONSerialization.data(withJSONObject: frame), as: UTF8.self)
    }

    @Test func readsReachTheWireWithoutAGesture() throws {
        let text = try Self.text("_acpmux/context", ["sessionId": "own"])
        guard case .frame(let facts, let box) = AgentPaneTransport.checkOne(text, Self.snapshot()) else {
            Issue.record("Context read was refused before reaching the wire")
            return
        }
        #expect(facts.free)
        #expect(!facts.needsGesture)
        #expect(box.encoded(id: nil) != nil)
    }

    @Test(arguments: ["user", "project"])
    func editsEmptyOverridesAndResetsWaitForThePersonsClick(scope: String) throws {
        let values: [Any] = ["Read independent sources concurrently.", "", NSNull()]
        for text in values {
            let params: [String: Any] = ["sessionId": "own", "scope": scope, "text": text]
            let frame = try Self.text("_acpmux/context_override", params)
            guard case .frame(let facts, let box) = AgentPaneTransport.checkOne(frame, Self.snapshot()) else {
                Issue.record("Context edit was refused before reaching the wire")
                continue
            }
            #expect(facts.needsGesture)
            #expect(!facts.free)
            let encoded = try #require(box.encoded(id: nil))
            let object = try #require(JSONSerialization.jsonObject(with: Data(encoded.utf8)) as? [String: Any])
            let sent = try #require(object["params"] as? [String: Any])
            #expect(NSDictionary(dictionary: sent).isEqual(to: params))
        }
    }

    @Test(arguments: ["_acpmux/context", "_acpmux/context_override"])
    func foreignOrMissingSessionsCannotReadOrEdit(method: String) throws {
        let sessions: [Any] = ["foreign", NSNull(), 7]
        for session in sessions {
            let frame = try Self.text(method, ["sessionId": session])
            guard case .refuse(.refuse(.sessionNotInPane, _, _), _) = AgentPaneTransport.checkOne(frame, Self.snapshot()) else {
                Issue.record("Context request escaped the pane's session scope")
                continue
            }
        }
        let frame = try Self.text(method, [:])
        guard case .refuse(.refuse(.sessionNotInPane, _, _), _) = AgentPaneTransport.checkOne(frame, Self.snapshot()) else {
            Issue.record("Context request accepted a missing session")
            return
        }
    }

    @Test(arguments: ["_acpmux/context", "_acpmux/context_override"])
    func forgedParamsAndMetadataAreRefused(method: String) throws {
        for key in ["cwd", "host", "unknown", "_meta"] {
            let frame = try Self.text(method, ["sessionId": "own", key: "/other/project"])
            guard case .refuse(.refuse(.intentInvalid, _, _), _) = AgentPaneTransport.checkOne(frame, Self.snapshot()) else {
                Issue.record("Context request accepted \(key)")
                continue
            }
        }
    }

    @Test(arguments: ["_acpmux/context", "_acpmux/context_override"])
    func contextCannotReplaceTheHandshake(method: String) throws {
        let frame = try Self.text(method, ["sessionId": "own"])
        guard case .refuse(.refuse(.firstFrameNotInitialize, _, _), _) = AgentPaneTransport.checkOne(frame, Self.snapshot(first: true)) else {
            Issue.record("Context bypassed the initialize handshake")
            return
        }
    }
}
