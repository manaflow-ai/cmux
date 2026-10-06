import Foundation
import Testing
@testable import CmuxNextAgentPane

@Suite struct AgentPaneHandshakeTests {
    private let endpoint = AcpmuxConnection(url: URL(string: "ws://127.0.0.1:47811/")!, dashboardToken: "secret",
                                            localAppToken: String(repeating: "f6", count: 32))

    @Test func aNewChatAsksThePageNotToAttachTheMostRecentSession() {
        let handshake = AgentPaneHandshake.acpmux(endpoint, sessionId: nil)
        #expect(handshake.protocolVersion == 2)
        #expect(handshake.transport == .acpmuxBridge)
        #expect(handshake.connection == endpoint)
        #expect(handshake.newSession == true)
    }

    @Test func aKnownSessionIsReattached() {
        let handshake = AgentPaneHandshake.acpmux(endpoint, sessionId: "s-1")
        #expect(handshake.sessionId == "s-1")
        #expect(handshake.newSession == nil)
    }

    /// Field names are the TypeScript `AcpmuxHostConfig` contract. The page gets no endpoint
    /// and no token: the connection stays with the host.
    @Test func encodesTheFieldNamesThePageReads() throws {
        let data = try JSONEncoder().encode(AgentPaneHandshake.acpmux(endpoint, sessionId: "s-1"))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["protocolVersion", "transport", "sessionId"])
        #expect(object["transport"] as? String == "acpmux-bridge")
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("secret") && !text.contains("f6f6") && !text.contains("47811"))
        let reply = AgentPaneReply.handshake(AgentPaneHandshake.acpmux(endpoint, sessionId: "s-1"))
        #expect(!String(describing: reply).contains("secret"))
    }

    @Test func theReplyLeavesUnsetFieldsOut() throws {
        let reply = AgentPaneReply.handshake(.mock)
        #expect(reply["ok"] as? Bool == true)
        let value = try #require(reply["value"] as? [String: Any])
        #expect(Set(value.keys) == ["protocolVersion", "transport", "handoffStrings", "checkpointStrings"])
        #expect(value["transport"] as? String == "mock")
    }

    @Test func theHandshakeCarriesLocalizedContinuationLabels() throws {
        let reply = AgentPaneReply.handshake(.mock)
        let value = try #require(reply["value"] as? [String: Any])
        let labels = try #require(value["handoffStrings"] as? [String: String])
        #expect(Set(labels.keys) == Set(AgentPaneHandoffStrings().values.keys))
        #expect(labels.count == 36)
        #expect(labels["continueIn"] == "Continue in…")
        #expect(labels["fromTo"]?.contains("%@") == true)
        #expect(labels["memoryLimit"]?.contains("32") == true)
        let checkpointLabels = try #require(value["checkpointStrings"] as? [String: String])
        #expect(checkpointLabels.count == 39)
        #expect(checkpointLabels["title"] == "Repository checkpoint")
        #expect(checkpointLabels["createCheckpoint"] == "Create checkpoint")
    }

    @Test func decodesPageRequests() {
        #expect(AgentPaneRequest(body: ["id": "1", "method": "ready", "params": [:]]) == .ready)
        #expect(AgentPaneRequest(body: ["method": "chat.persistSession", "params": ["sessionId": "s-2"]]) == .persistSession("s-2"))
        #expect(AgentPaneRequest(body: ["method": "chat.persistSession", "params": ["sessionId": ""]]) == .unsupported("chat.persistSession"))
        #expect(AgentPaneRequest(body: ["method": "pane.framePacing", "params": ["intervals": [6.25, 12.5]]]) == .framePacing([6.25, 12.5]))
        #expect(AgentPaneRequest(body: ["method": "pane.renderRate", "params": ["full": false]]) == .renderRate(false))
        #expect(AgentPaneRequest(body: ["method": "pane.renderRate", "params": ["full": "false"]]) == .unsupported("pane.renderRate"))
        #expect(AgentPaneRequest(body: ["method": "pane.framePacing", "params": ["intervals": [Double]()]]) == .unsupported("pane.framePacing"))
        #expect(AgentPaneRequest(body: ["method": "pane.checkpointAvailability", "params": ["available": true]]) == .checkpointAvailability(true))
        #expect(AgentPaneRequest(body: ["method": "pane.checkpointAvailability", "params": ["available": "yes"]]) == .unsupported("pane.checkpointAvailability"))
        let long = AgentPaneRequest(body: ["method": "pane.framePacing", "params": ["intervals": Array(repeating: 6.25, count: 1000)]])
        #expect(long == .framePacing(Array(repeating: 6.25, count: AgentPaneRequest.maximumPacingFrames)))
        #expect(AgentPaneRequest(body: ["method": "chat.send", "params": ["text": "hi"]]) == .unsupported("chat.send"))
        #expect(AgentPaneRequest(body: "ready") == .unsupported(""))
    }
}
