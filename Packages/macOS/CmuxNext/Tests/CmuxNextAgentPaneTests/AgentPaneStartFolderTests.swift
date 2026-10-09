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

    /// The New Tab page lists every open tab's folder as a pick (gesture roots); a fresh workspace's
    /// terminal at `~` lists `~` and one at `/Users` lists that. A click never makes either a root.
    @Test func theNewTabPagesFoldersNeverMakeTheHomeFolderARoot() async throws {
        let rig = AgentPaneProductRulesTests.Rig()
        try await rig.start()
        defer { rig.server.stop() }
        let home = rig.folder("users/me"), above = rig.folder("users")
        rig.transport.homeFolder = home
        rig.transport.gestureRoots = { [home, above] }
        for folder in [home, above] {
            rig.transport.gestures.record()
            let refused = await rig.send("session/new", ["cwd": folder, "mcpServers": [Any]()], expect: .pathOutsideRoots)
            #expect(await rig.received(refused) == nil, "\(folder)")
        }
        #expect(rig.transport.addedRoots.isEmpty)
    }

    /// A path that is no folder gets the host's refusal, never the "older host" fallback.
    @Test func aPathThatIsNoFolderIsRefused() async {
        let model = AgentPaneModel(host: MockAgentPaneHost())
        let reply = await model.respond(to: Self.useFolder("~/project"))
        #expect(reply["ok"] as? Bool == false)
        #expect((reply["error"] as? [String: Any])?["code"] as? String == AgentPaneTransportError.pathInvalid.rawValue)
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

    // MARK: The store's answer (workspace.agent_start.get, cx-9aps)

    /// The pane asks the store with the folder it would propose, and the handshake carries only
    /// the answer: a workspace without a folder starts in its private folder, and the page offers
    /// Choose Folder…; the relay fills `session/new` with that same folder.
    @Test func theHandshakeShowsTheStoresAnswer() async throws {
        let rig = AgentPaneProductRulesTests.Rig()
        try await rig.start()
        defer { rig.server.stop() }
        let home = rig.folder("home"), agentHome = rig.folder("support/cmux/agent-home/ws-1")
        let model = AgentPaneModel(host: MockAgentPaneHost(), seed: AgentPaneSeedSource(AgentPaneSeed(cwd: home)),
                                   transport: rig.transport)
        var proposed: [String?] = []
        model.resolveStartFolder = { cwd in
            proposed.append(cwd)
            return AgentPaneStartFolder(kind: .agentHome, cwd: agentHome, agentHome: agentHome, skipped: (home, .home))
        }
        model.onChooseFolder = { .cancelled }
        let handshake = try #require(Self.value(await model.respond(to: .ready)))
        #expect(proposed == [home])
        #expect(handshake["cwd"] == nil)
        #expect(handshake["startKind"] as? String == "agent_home")
        #expect(handshake["chooseFolder"] as? Bool == true)
        let chat = await rig.send("session/new", ["mcpServers": [Any]()])
        #expect(await rig.cwd(chat) == agentHome)
    }

    @Test func aWorkspaceFolderFromTheStoreIsTheChatsFolder() async throws {
        let rig = AgentPaneProductRulesTests.Rig()
        try await rig.start()
        defer { rig.server.stop() }
        let project = rig.folder("project")
        let model = AgentPaneModel(host: MockAgentPaneHost(), transport: rig.transport)
        var folders = [project]
        model.workspaceRoots = { folders }
        model.resolveStartFolder = { _ in AgentPaneStartFolder(kind: .workspace, cwd: project, agentHome: nil) }
        let handshake = try #require(Self.value(await model.respond(to: .ready)))
        #expect(handshake["cwd"] as? String == project)
        #expect(handshake["startKind"] as? String == "workspace")
        #expect(handshake["chooseFolder"] == nil)
        let chat = await rig.send("session/new", ["mcpServers": [Any]()])
        #expect(await rig.cwd(chat) == project)
        // The workspace dropped the folder: it is no longer the fill or a root.
        folders = []
        #expect(model.primaryRoot() == nil)
        #expect(!model.roots().contains(project))
    }

    /// Review: a pick the store calls home is granted only when it is this Mac's own home folder.
    @Test func aHomeAnswerForAnotherFolderGrantsNothing() async throws {
        let rig = AgentPaneProductRulesTests.Rig()
        try await rig.start()
        defer { rig.server.stop() }
        let home = rig.folder("home"), other = rig.folder("other")
        rig.transport.homeFolder = home
        let model = AgentPaneModel(host: MockAgentPaneHost(), transport: rig.transport)
        model.resolveStartFolder = { cwd in AgentPaneStartFolder(kind: .agentHome, cwd: nil, agentHome: nil, skipped: (cwd ?? "", .home)) }
        rig.transport.gestures.record()
        let reply = await model.respond(to: Self.useFolder(other, confirm: true))
        #expect(reply["ok"] as? Bool == false)
        #expect(rig.transport.addedRoots.isEmpty)
    }

    /// A pick goes through the store too: its `home` reason is the question, `above_home` the refusal.
    @Test func aPickUsesTheStoresReason() async throws {
        let rig = AgentPaneProductRulesTests.Rig()
        try await rig.start()
        defer { rig.server.stop() }
        let home = rig.folder("home"), project = rig.folder("project")
        rig.transport.homeFolder = home
        let model = AgentPaneModel(host: MockAgentPaneHost(), transport: rig.transport)
        model.resolveStartFolder = { cwd in
            if cwd == home { return AgentPaneStartFolder(kind: .agentHome, cwd: nil, agentHome: nil, skipped: (home, .home)) }
            if cwd == "/" { return AgentPaneStartFolder(kind: .agentHome, cwd: nil, agentHome: nil, skipped: ("/", .aboveHome)) }
            return AgentPaneStartFolder(kind: .seed, cwd: cwd, agentHome: nil)
        }
        #expect(Self.value(await model.respond(to: Self.useFolder(project)))?["cwd"] as? String == project)
        #expect(Self.value(await model.respond(to: Self.useFolder(home)))?["status"] as? String == "confirm")
        #expect(Self.value(await model.respond(to: Self.useFolder("/")))?["status"] as? String == "refused")
        rig.transport.gestures.record()
        #expect(Self.value(await model.respond(to: Self.useFolder(home, confirm: true)))?["status"] as? String == "ok")
        #expect(rig.transport.addedRoots == [home])
    }
}
