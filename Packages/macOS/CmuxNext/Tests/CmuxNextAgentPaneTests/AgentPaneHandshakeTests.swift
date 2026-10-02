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
        #expect(AgentPaneRequest(body: ["method": "pane.framePacing", "params": ["intervals": [6.25, 12.5]]]) == .framePacing([6.25, 12.5]))
        #expect(AgentPaneRequest(body: ["method": "pane.framePacing", "params": ["intervals": [Double]()]]) == .unsupported("pane.framePacing"))
        let long = AgentPaneRequest(body: ["method": "pane.framePacing", "params": ["intervals": Array(repeating: 6.25, count: 1000)]])
        #expect(long == .framePacing(Array(repeating: 6.25, count: AgentPaneRequest.maximumPacingFrames)))
        #expect(AgentPaneRequest(body: ["method": "chat.send", "params": ["text": "hi"]]) == .unsupported("chat.send"))
        #expect(AgentPaneRequest(body: "ready") == .unsupported(""))
    }

    @Test func decodesTheInspectorExport() {
        let name = "acp-0123abcd-20261001-120000.jsonl"
        #expect(AgentPaneRequest(body: ["method": "pane.saveLog", "params": ["text": "{}\n", "suggestedName": name]])
            == .saveLog(text: "{}\n", suggestedName: name))
        #expect(AgentPaneRequest(body: ["method": "pane.saveLog", "params": ["text": "{}\n"]])
            == .saveLog(text: "{}\n", suggestedName: AgentPaneRequest.defaultLogName))
        #expect(AgentPaneRequest(body: ["method": "pane.saveLog", "params": ["text": ""]]) == .unsupported("pane.saveLog"))
        #expect(AgentPaneRequest(body: ["method": "pane.saveLog", "params": ["text": 3]]) == .unsupported("pane.saveLog"))
    }

    /// The page's log is bounded near 2M characters; anything past the cap
    /// is refused before a save panel opens.
    @Test func theExportIsCappedInUTF8Bytes() {
        let atCap = String(repeating: "a", count: AgentPaneRequest.maximumLogBytes)
        #expect(AgentPaneRequest(body: ["method": "pane.saveLog", "params": ["text": atCap]]) == .saveLog(text: atCap, suggestedName: "acp.jsonl"))
        let over = atCap + "a"
        #expect(AgentPaneRequest(body: ["method": "pane.saveLog", "params": ["text": over]]) == .unsupported("pane.saveLog"))
        // Multi-byte text counts its bytes, not its characters.
        let wide = String(repeating: "é", count: AgentPaneRequest.maximumLogBytes / 2 + 1)
        #expect(AgentPaneRequest(body: ["method": "pane.saveLog", "params": ["text": wide]]) == .unsupported("pane.saveLog"))
    }

    @Test func theSuggestedNameStaysAPlainJSONLinesFileName() {
        #expect(AgentPaneRequest.logFileName("acp-1.jsonl") == "acp-1.jsonl")
        #expect(AgentPaneRequest.logFileName("acp-1") == "acp-1.jsonl")
        #expect(AgentPaneRequest.logFileName("../../etc/passwd") == "etcpasswd.jsonl")
        #expect(AgentPaneRequest.logFileName("a:b\\c\nd") == "abcd.jsonl")
        #expect(AgentPaneRequest.logFileName(".jsonl") == AgentPaneRequest.defaultLogName)
        #expect(AgentPaneRequest.logFileName("   ") == AgentPaneRequest.defaultLogName)
        #expect(AgentPaneRequest.logFileName(nil) == AgentPaneRequest.defaultLogName)
        #expect(AgentPaneRequest.logFileName(String(repeating: "x", count: 500)).count == 120)
    }
}
