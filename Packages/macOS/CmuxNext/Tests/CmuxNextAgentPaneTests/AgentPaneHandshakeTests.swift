import Foundation
import Testing
@testable import CmuxNextAgentPane

@Suite struct AgentPaneHandshakeTests {
    private let endpoint = AcpmuxWebEndpoint(url: URL(string: "ws://127.0.0.1:47811/")!, token: "secret")

    @Test func aNewChatAsksThePageNotToAttachTheMostRecentSession() {
        let handshake = AgentPaneHandshake.acpmux(endpoint, sessionId: nil)
        #expect(handshake.protocolVersion == 1)
        #expect(handshake.transport == .acpmuxWebSocket)
        #expect(handshake.endpoint == "ws://127.0.0.1:47811/")
        #expect(handshake.token == "secret")
        #expect(handshake.newSession == true)
    }

    @Test func aKnownSessionIsReattached() {
        let handshake = AgentPaneHandshake.acpmux(endpoint, sessionId: "s-1")
        #expect(handshake.sessionId == "s-1")
        #expect(handshake.newSession == nil)
    }

    /// Field names are the TypeScript `AcpmuxHostConfig` contract.
    @Test func encodesTheFieldNamesThePageReads() throws {
        let data = try JSONEncoder().encode(AgentPaneHandshake.acpmux(endpoint, sessionId: "s-1"))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["protocolVersion", "transport", "endpoint", "token", "sessionId"])
        #expect(object["transport"] as? String == "acpmux-websocket")
    }

    @Test func theReplyLeavesUnsetFieldsOut() throws {
        let reply = AgentPaneReply.handshake(.mock)
        #expect(reply["ok"] as? Bool == true)
        let value = try #require(reply["value"] as? [String: Any])
        #expect(Set(value.keys) == ["protocolVersion", "transport"])
        #expect(value["transport"] as? String == "mock")
    }

    @Test func decodesPageRequests() {
        #expect(AgentPaneRequest(body: ["id": "1", "method": "ready", "params": [:]]) == .ready)
        #expect(AgentPaneRequest(body: ["method": "chat.persistSession", "params": ["sessionId": "s-2"]]) == .persistSession("s-2"))
        #expect(AgentPaneRequest(body: ["method": "chat.persistSession", "params": ["sessionId": ""]]) == .unsupported("chat.persistSession"))
        #expect(AgentPaneRequest(body: ["method": "chat.send", "params": ["text": "hi"]]) == .unsupported("chat.send"))
        #expect(AgentPaneRequest(body: "ready") == .unsupported(""))
    }
}
