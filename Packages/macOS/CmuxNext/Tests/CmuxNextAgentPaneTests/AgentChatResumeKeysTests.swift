import Foundation
import Testing
@testable import CmuxNextAgentPane

/// Resume from Transcript opens the exact chat (Lawrence 2026-10-21, "make it one step"): the app
/// keeps each shown session's chat-index key across relaunches, and the page reads it back.
@MainActor
struct AgentChatResumeKeysTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
        func sessionFolder(sessionId: String) async throws -> AgentPaneSessionFolder? { nil }
        func putFile(sessionId: String, name: String, data: Data) async throws -> String { "" }
    }

    private func file() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("resume-keys-\(UUID().uuidString).json")
    }

    @Test func aKeptKeySurvivesARelaunch() {
        let file = file()
        defer { try? FileManager.default.removeItem(at: file) }
        AgentChatResumeKeys(file: file).set("claude-code:01a1201b-d407", for: "01a1201b-d3c3")
        #expect(AgentChatResumeKeys(file: file).key(for: "01a1201b-d3c3") == "claude-code:01a1201b-d407")
        #expect(AgentChatResumeKeys(file: file).key(for: "other") == nil)
    }

    @Test func thePageKeepsAndReadsAKey() async {
        let model = AgentPaneModel(host: NoHost())
        model.resumeKeys = AgentChatResumeKeys(file: nil)
        _ = await model.respond(to: AgentPaneRequest(body: ["method": "chat.resumeKey",
                                                            "params": ["session": "s1", "key": "codex:019a"]]))
        let reply = await model.respond(to: AgentPaneRequest(body: ["method": "chat.resumeKey.get", "params": ["session": "s1"]]))
        #expect((reply["value"] as? [String: Any])?["key"] as? String == "codex:019a")
    }

    @Test func refusesAKeyThatIsNotAChatIndexKey() {
        #expect(AgentPaneRequest(body: ["method": "chat.resumeKey", "params": ["session": "s", "key": "file:/etc/passwd"]])
            == .unsupported("chat.resumeKey"))
        #expect(AgentPaneRequest(body: ["method": "chat.resumeKey", "params": ["session": "s", "key": "claude-code:../x"]])
            == .unsupported("chat.resumeKey"))
    }
}
