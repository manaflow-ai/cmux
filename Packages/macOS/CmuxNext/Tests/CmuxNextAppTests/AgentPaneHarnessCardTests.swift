@testable import CmuxNextAgentPane
import Foundation
import Testing
import CmuxNextWakeups

/// The agent CLI card's Restart Chat (cx-1mbnu) restarts only a chat this pane started or shows:
/// a page that adopts another chat's id (`chat.persistSession`) and then asks for a restart is
/// refused before anything reaches acpmux, so it cannot restart other chats' agents.
@MainActor
struct AgentPaneHarnessCardTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    /// A pane with an acpmux socket that does not answer: a request that reaches it fails as
    /// `harness.failed`, one refused first never gets there.
    private static func pane() -> AgentPaneModel {
        let model = AgentPaneModel(runner: BackgroundWork(label: "test.agent-pane"), host: NoHost())
        model.transport.acpmuxSocket = FileManager.default.temporaryDirectory.appending(path: "no-acpmux-\(UUID().uuidString).sock").path
        return model
    }

    private static func restart(_ model: AgentPaneModel, adopting id: String) async -> String? {
        _ = await model.respond(to: AgentPaneRequest(body: ["method": "chat.persistSession", "params": ["sessionId": id]]))
        model.transport.gestures.record()
        let reply = await model.respond(to: AgentPaneRequest(body: ["method": "harness.restart", "params": [:]]))
        return (reply["error"] as? [String: Any])?["code"] as? String
    }

    @Test func restartOfAChatThePaneDoesNotShowIsRefused() async {
        #expect(await Self.restart(Self.pane(), adopting: "someone-elses-chat") == "harness.not_this_chat")
    }

    @Test func restartOfThePanesOwnChatGoesToAcpmux() async {
        let model = Self.pane()
        model.transport.sessions.add("this-chat")
        #expect(await Self.restart(model, adopting: "this-chat") == "harness.failed")
    }
}
