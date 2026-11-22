import Foundation
import Testing
@testable import CmuxNextAgentPane

/// "Choose Folder…" (AGENT-CWD-FOR-FOLDERLESS-WORKSPACE): the page asks the host for the native
/// folder sheet (`workspace.chooseFolder`). The host shows it only after a real user gesture (the
/// relay's grant credit); a picked folder becomes the workspace's agent folder, and the next new
/// chat starts there instead of agent-home.
@MainActor
@Suite(.serialized) struct AgentPaneChooseFolderTests {
    @Test func theRequestDecodesFromBothBridges() {
        #expect(AgentPaneRequest(body: ["method": "workspace.chooseFolder", "params": [String: Any]()]) == .chooseFolder)
        #expect(AgentPageOps.method(for: "cmux.agent.workspace.chooseFolder") == "workspace.chooseFolder")
    }

    @Test func withoutAGestureTheSheetIsRefused() async {
        let model = AgentPaneModel(host: MockAgentPaneHost())
        var asked = 0
        model.onChooseFolder = { asked += 1; return .chosen("/tmp") }
        let reply = await model.respond(to: .chooseFolder)
        #expect(reply["ok"] as? Bool == false)
        #expect((reply["error"] as? [String: Any])?["code"] as? String == AgentPaneTransportError.gestureRequired.rawValue)
        #expect(asked == 0)
        #expect(model.chosenFolder == nil)
    }

    @Test func aGestureShowsTheSheetOnceAndTheNextNewChatUsesTheFolder() async throws {
        let rig = AgentPaneProductRulesTests.Rig()
        try await rig.start()
        defer { rig.server.stop() }
        let model = AgentPaneModel(host: MockAgentPaneHost(), transport: rig.transport)
        let project = rig.folder("project")
        let home = AgentHome(base: rig.folder("support") + "/cmux/agent-home")
        model.workspaceRoots = { [] }
        model.workspaceAgentHome = { AgentHomeFill(home: home, workspace: "ws-home") }
        // Before: the chat starts in agent-home.
        let before = await rig.send("session/new", ["mcpServers": [Any]()])
        #expect(await rig.cwd(before) == home.base + "/ws-home")

        var asked = 0
        model.onChooseFolder = { asked += 1; return .chosen(project) }
        rig.transport.gestures.record()
        let reply = await model.respond(to: .chooseFolder)
        #expect(reply["ok"] as? Bool == true)
        #expect((reply["value"] as? [String: Any])?["cwd"] as? String == project)
        #expect(asked == 1)
        #expect(model.chosenFolder == project)
        // The gesture's grant credit is spent: a second request without a new gesture is refused.
        let again = await model.respond(to: .chooseFolder)
        #expect(again["ok"] as? Bool == false)
        #expect(asked == 1)

        // The next new chat starts in the chosen folder; agent-home stays a root for running chats.
        let after = await rig.send("session/new", ["mcpServers": [Any]()])
        #expect(await rig.cwd(after) == project)
        let running = await rig.send("session/new", ["cwd": home.base + "/ws-home", "mcpServers": [Any]()])
        #expect(await rig.cwd(running) == home.base + "/ws-home")
    }

    @Test func aCancelledSheetChangesNothing() async {
        let model = AgentPaneModel(host: MockAgentPaneHost())
        model.onChooseFolder = { .cancelled }
        model.transport.gestures.record()
        let reply = await model.respond(to: .chooseFolder)
        #expect(reply["ok"] as? Bool == true)
        #expect(model.chosenFolder == nil)
    }

    /// An older background service (kept running across an app update) cannot save the folder:
    /// the page gets the localized restart message as a refusal, and new chats still start in
    /// agent-home.
    @Test func anOldDaemonShowsTheRestartMessageAndTheChatStillStartsInAgentHome() async throws {
        let rig = AgentPaneProductRulesTests.Rig()
        try await rig.start()
        defer { rig.server.stop() }
        let model = AgentPaneModel(host: MockAgentPaneHost(), transport: rig.transport)
        let home = AgentHome(base: rig.folder("support") + "/cmux/agent-home")
        model.workspaceRoots = { [] }
        model.workspaceAgentHome = { AgentHomeFill(home: home, workspace: "ws-old") }
        model.onChooseFolder = { .unavailable(AgentPaneFolderChoice.restartServiceMessage) }
        rig.transport.gestures.record()
        let reply = await model.respond(to: .chooseFolder)
        #expect(reply["ok"] as? Bool == false)
        let error = reply["error"] as? [String: Any]
        #expect(error?["code"] as? String == AgentPaneFolderChoice.unavailableCode)
        #expect(error?["userMessage"] as? String == AgentPaneFolderChoice.restartServiceMessage)
        #expect(!AgentPaneFolderChoice.restartServiceMessage.isEmpty)
        #expect(model.chosenFolder == nil)
        let chat = await rig.send("session/new", ["mcpServers": [Any]()])
        #expect(await rig.cwd(chat) == home.base + "/ws-old")
    }
}
