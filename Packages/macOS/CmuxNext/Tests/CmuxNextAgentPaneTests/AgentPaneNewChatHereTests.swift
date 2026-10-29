import Testing
@testable import CmuxNextAgentPane
import CmuxNextWakeups

/// Leo 2026-10-13: a started chat's folder is fixed; its folder menu's New Chat Here (or another
/// folder) asks the host for a new chat in that folder (`chat.newHere`), in a tab of its own.
@Suite
@MainActor
struct AgentPaneNewChatHereTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    /// The folders the host opened a new chat in.
    @MainActor private final class Opened { var folders: [String] = [] }

    private static func pane(_ opened: Opened, sessionId: String? = "chat") -> AgentPaneModel {
        let model = AgentPaneModel(runner: BackgroundWork(label: "test.agent-pane"), host: NoHost(), sessionId: sessionId)
        model.header = AgentPaneHeaderHooks(run: { _, _ in }, tabState: { AgentPaneHeaderState() }, newChat: {
            opened.folders.append($0)
            return true
        })
        return model
    }

    private static func newHere(_ cwd: String) -> AgentPaneRequest {
        AgentPaneRequest(body: ["method": "chat.newHere", "params": ["cwd": cwd]])
    }

    @Test func newChatHereOpensANewChatInThatFolderAndTheChatStays() async {
        let opened = Opened()
        let model = Self.pane(opened)
        let reply = await model.respond(to: Self.newHere("/work/site"))
        #expect(reply["ok"] as? Bool == true)
        #expect(opened.folders == ["/work/site"])
        #expect(model.sessionId == "chat")
    }

    @Test func aRelativeFolderOrAPaneWithNoChatOpensNothing() async {
        let opened = Opened()
        _ = await Self.pane(opened).respond(to: Self.newHere("work/site"))
        _ = await Self.pane(opened, sessionId: nil).respond(to: Self.newHere("/work/site"))
        #expect(opened.folders.isEmpty)
    }
}
