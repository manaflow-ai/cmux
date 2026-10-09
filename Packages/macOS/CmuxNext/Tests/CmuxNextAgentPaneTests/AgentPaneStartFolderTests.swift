import Foundation
import Testing
@testable import CmuxNextAgentPane

/// cx-nn3e (Lawrence 2026-10-09): a new chat's folder chip said `~` while the line under it said
/// the chat starts in a private folder; the start failed with "This folder is outside the folders
/// this pane may use" and a Retry, and an Add Folder sheet floated at the pane's corner at the same
/// time. The host owns where a new chat starts: the handshake names that folder, the home folder
/// (or anything above it) is never a root by a plain click, and choosing it is asked once, in the
/// pane, before the chat starts (`workspace.useFolder`).
@MainActor
@Suite(.serialized) struct AgentPaneStartFolderTests {
    static func useFolder(_ cwd: String, confirm: Bool = false) -> AgentPaneRequest {
        AgentPaneRequest(body: ["method": "workspace.useFolder", "params": ["cwd": cwd, "confirm": confirm]])
    }

    static func value(_ reply: [String: Any]) -> [String: Any]? { reply["value"] as? [String: Any] }

    @Test func theRequestDecodesFromBothBridges() {
        let request = Self.useFolder("/tmp/project", confirm: true)
        #expect(request != .unsupported("workspace.useFolder"))
        #expect(AgentPageOps.method(for: "cmux.agent.workspace.useFolder") == "workspace.useFolder")
    }

    /// The page's typed-folder rule (a click adds a folder outside every root) never covers the
    /// home folder: a chat there could read the whole home folder, and macOS asks for Photos,
    /// Documents and more. Without the user's answer to the question it stays refused.
    @Test func aClickNeverMakesTheHomeFolderARootByItself() async throws {
        let rig = AgentPaneProductRulesTests.Rig()
        try await rig.start()
        defer { rig.server.stop() }
        let root = rig.root, home = rig.folder("home")
        rig.transport.homeFolder = home
        rig.transport.roots = { [root] }
        rig.transport.gestures.record()
        let refused = await rig.send("session/new", ["cwd": home, "mcpServers": [Any]()], expect: .pathOutsideRoots)
        #expect(await rig.received(refused) == nil)
        #expect(rig.transport.addedRoots.isEmpty)
    }

    /// A project folder needs no question. The home folder is asked about first; the answer's
    /// click makes it a root, and the chat then starts there at once, without another click.
    @Test func theHomeFolderIsAskedOnceAndTheAnswerStartsTheChat() async throws {
        let rig = AgentPaneProductRulesTests.Rig()
        try await rig.start()
        defer { rig.server.stop() }
        let model = AgentPaneModel(host: MockAgentPaneHost(), transport: rig.transport)
        let home = rig.folder("home"), project = rig.folder("project")
        rig.transport.homeFolder = home
        model.workspaceRoots = { [] }

        let plain = Self.value(await model.respond(to: Self.useFolder(project)))
        #expect(plain?["status"] as? String == "ok")
        #expect(plain?["cwd"] as? String == project)

        let ask = Self.value(await model.respond(to: Self.useFolder(home)))
        #expect(ask?["status"] as? String == "confirm")
        #expect(ask?["reason"] as? String == "home")
        #expect(rig.transport.addedRoots.isEmpty)

        // The answer without a click (a script) is refused.
        let scripted = await model.respond(to: Self.useFolder(home, confirm: true))
        #expect(scripted["ok"] as? Bool == false)
        #expect((scripted["error"] as? [String: Any])?["code"] as? String == AgentPaneTransportError.gestureRequired.rawValue)
        #expect(rig.transport.addedRoots.isEmpty)

        rig.transport.gestures.record()
        let answered = Self.value(await model.respond(to: Self.useFolder(home, confirm: true)))
        #expect(answered?["status"] as? String == "ok")
        #expect(rig.transport.addedRoots == [home])
        let chat = await rig.send("session/new", ["cwd": home, "mcpServers": [Any]()])
        #expect(await rig.cwd(chat) == home)
    }

    /// `/` and the folders above the home folder are never a chat's folder, not even with an answer.
    @Test func theRootAndTheFoldersAboveHomeAreRefused() async throws {
        let rig = AgentPaneProductRulesTests.Rig()
        try await rig.start()
        defer { rig.server.stop() }
        let model = AgentPaneModel(host: MockAgentPaneHost(), transport: rig.transport)
        let home = rig.folder("users/me")
        let above = rig.folder("users")
        rig.transport.homeFolder = home
        for folder in ["/", above] {
            #expect(Self.value(await model.respond(to: Self.useFolder(folder)))?["status"] as? String == "refused", "\(folder)")
            rig.transport.gestures.record()
            #expect(Self.value(await model.respond(to: Self.useFolder(folder, confirm: true)))?["status"] as? String == "refused", "\(folder)")
        }
        #expect(rig.transport.addedRoots.isEmpty)
    }

    /// The page shows the folder the chat starts in: a workspace with a folder names it in the
    /// handshake, so the chip and the start agree (the chip said "Choose folder" while the chat
    /// started in the workspace's folder).
    @Test func theHandshakeNamesTheWorkspaceFolderANewChatStartsIn() async throws {
        let project = FileManager.default.temporaryDirectory.appendingPathComponent("start-folder-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: project) }
        let model = AgentPaneModel(host: MockAgentPaneHost())
        model.workspaceRoots = { [NSHomeDirectory(), project] }
        let handshake = try #require(Self.value(await model.respond(to: .ready)))
        #expect(handshake["cwd"] as? String == project)
        #expect(handshake["chooseFolder"] == nil)
    }
}
