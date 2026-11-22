import Darwin
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// AGENT-CWD-FOR-FOLDERLESS-WORKSPACE: a workspace without a folder (the default Home workspace)
/// gives new agent chats their own folder, `agent-home/<workspace-id>` (0700, created on first use),
/// which is the chat's cwd and its only root. Never the home folder.
@MainActor
@Suite(.serialized) struct AgentHomeTests {
    /// A canonical temporary `agent-home` base (`/var` is a symlink to `/private/var`).
    private func base() throws -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("agent-home-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return try #require(AcpmuxPathPolicy.canonical(url.path)) + "/cmux/agent-home"
    }

    private func mode(_ path: String) -> mode_t {
        var info = stat()
        return lstat(path, &info) == 0 ? info.st_mode & 0o777 : 0
    }

    @Test func ensureCreatesThePrivateFolderOnFirstUse() throws {
        let home = AgentHome(base: try base())
        let path = try #require(home.ensure("ws-1"))
        #expect(path == home.base + "/ws-1")
        #expect(AcpmuxPathPolicy.isDirectory(path))
        #expect(mode(path) == 0o700)
        #expect(mode(home.base) == 0o700)
        // Again: the same folder; a looser mode is made private again.
        chmod(path, 0o755)
        #expect(home.ensure("ws-1") == path)
        #expect(mode(path) == 0o700)
    }

    /// acpmux trusts an agent-home folder by construction only when it holds the app's marker
    /// (`.cmux-agent-home`, a regular file): ensure writes it, also into a folder an older build
    /// made without one, so a new chat there is never stopped by the folder trust question.
    @Test func ensureMarksTheFolderAsMadeByCmux() throws {
        let home = AgentHome(base: try base())
        let path = try #require(home.ensure("ws-mark"))
        let marker = path + "/.cmux-agent-home"
        var info = stat()
        #expect(lstat(marker, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG)
        // A folder from before the marker gets it on its next use.
        unlink(marker)
        #expect(home.ensure("ws-mark") == path)
        #expect(lstat(marker, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG)
    }

    @Test func onlyASafeWorkspaceIdNamesAFolder() throws {
        let home = AgentHome(base: try base())
        for id in ["", ".", "..", "a/b", "../x", "x/..", "with space", "a\u{0}b", "é", String(repeating: "a", count: 129)] {
            #expect(home.ensure(id) == nil, "\(id)")
            #expect(home.path(for: id) == nil, "\(id)")
        }
        #expect(home.ensure("home") != nil)
        #expect(home.ensure("0b2c7f3e-d39d-4ab8-893a-676a00f6b8ac") != nil)
        #expect(home.ensure("ws_b287f9cec6d7f869da16b84b4b34a56f") != nil)
    }

    @Test func aSymlinkAnywhereInThePathIsRefused() throws {
        let root = try base()
        let outside = (root as NSString).deletingLastPathComponent + "/outside"
        try FileManager.default.createDirectory(atPath: outside, withIntermediateDirectories: true)
        // The workspace's own folder is a symlink.
        let home = AgentHome(base: root)
        _ = try #require(home.ensure("seed"))
        try FileManager.default.createSymbolicLink(atPath: root + "/ws-link", withDestinationPath: outside)
        #expect(home.ensure("ws-link") == nil)
        // The base is a symlink.
        let linked = (root as NSString).deletingLastPathComponent + "/linked-home"
        try FileManager.default.createSymbolicLink(atPath: linked, withDestinationPath: root)
        #expect(AgentHome(base: linked).ensure("ws-2") == nil)
        // A base that is not absolute, or not canonical.
        #expect(AgentHome(base: "relative/agent-home").ensure("ws-3") == nil)
        #expect(AgentHome(base: root + "/../agent-home").ensure("ws-4") == nil)
        // Nothing was made through a link.
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside).isEmpty)
    }

    @Test func theStandardBaseIsInApplicationSupportNeverTheHomeFolder() throws {
        let home = try #require(AgentHome.standard)
        #expect(home.base.hasSuffix("/Library/Application Support/cmux/agent-home"))
        #expect(home.base != NSHomeDirectory())
    }

    // MARK: The relay

    @Test func aNewChatInAFolderlessWorkspaceStartsInItsAgentHome() async throws {
        let rig = AgentPaneProductRulesTests.Rig()
        try await rig.start()
        defer { rig.server.stop() }
        rig.transport.roots = { [] }
        rig.transport.primaryRoot = { nil }
        // Without an agent home there is no folder: refused.
        await rig.send("session/new", ["mcpServers": [Any]()], expect: .pathInvalid)
        let home = AgentHome(base: try base())
        rig.transport.agentHome = { AgentHomeFill(home: home, workspace: "ws-home") }
        let chat = await rig.send("session/new", ["mcpServers": [Any]()])
        let expected = home.base + "/ws-home"
        #expect(await rig.cwd(chat) == expected)
        #expect(mode(expected) == 0o700)
        // It is the only root: a folder inside it passes, the home folder does not.
        try FileManager.default.createDirectory(atPath: expected + "/notes", withIntermediateDirectories: true)
        let inside = await rig.send("session/new", ["cwd": expected + "/notes", "mcpServers": [Any]()])
        #expect(await rig.cwd(inside) == expected + "/notes")
        await rig.send("session/new", ["cwd": NSHomeDirectory(), "mcpServers": [Any]()], expect: .pathOutsideRoots)
        // A workspace id that names no safe folder: refused, never a fallback to ~.
        rig.transport.agentHome = { AgentHomeFill(home: home, workspace: "../escape") }
        await rig.send("session/new", ["mcpServers": [Any]()], expect: .pathInvalid)
    }

    /// #17470: a fresh workspace opens on the chat-first New Tab page, its chat seeded with the
    /// daemon's default folder, the home folder. That inherited `~` is no chat folder: the page
    /// gets no cwd and the offer to choose one, and the chat starts in agent-home.
    @Test func aFreshWorkspaceNewTabPageChatStartsInAgentHomeNeverTheHomeFolder() async throws {
        let rig = AgentPaneProductRulesTests.Rig()
        try await rig.start()
        defer { rig.server.stop() }
        let userHome = rig.folder("home")
        let model = AgentPaneModel(host: MockAgentPaneHost(), seed: AgentPaneSeedSource(AgentPaneSeed(cwd: userHome)),
                                   newTab: AgentPaneNewTab(kind: .agent), transport: rig.transport)
        rig.transport.homeFolder = userHome
        let home = AgentHome(base: rig.folder("support") + "/cmux/agent-home")
        model.workspaceRoots = { [] }
        model.workspaceAgentHome = { AgentHomeFill(home: home, workspace: "ws-fresh") }
        model.onChooseFolder = { .cancelled }
        let handshake = await model.respond(to: .ready)["value"] as? [String: Any]
        #expect(handshake?["cwd"] == nil)
        #expect(handshake?["chooseFolder"] as? Bool == true)
        #expect(model.transport.primaryRoot() == nil)
        let chat = await rig.send("session/new", ["mcpServers": [Any]()])
        #expect(await rig.cwd(chat) == home.base + "/ws-fresh")
        // The home folder is no root, so the page cannot reach it.
        await rig.send("session/new", ["cwd": userHome, "mcpServers": [Any]()], expect: .pathOutsideRoots)
        // A workspace that has a folder still starts there, even with `~` inherited.
        let project = rig.folder("project")
        model.workspaceRoots = { [userHome, project] }
        let inProject = await rig.send("session/new", ["mcpServers": [Any]()])
        #expect(await rig.cwd(inProject) == project)
    }

    /// nxdog62 (2d88394fdea2): New Agent Chat (palette.newAgentChat, Cmd-I) from a terminal at
    /// `~` in a workspace with no other folder started Claude Code in `~`. The chat's seed is the
    /// terminal's cwd, and that terminal also makes `~` a workspace root. Neither is a chat folder
    /// or a root: the page gets no cwd and the offer to choose one, and the chat starts in
    /// agent-home. The same for a terminal at `/`.
    @Test func aNewChatFromATerminalAtTheHomeFolderStartsInAgentHomeNeverTheHomeFolder() async throws {
        for terminal in ["home", "/"] {
            let rig = AgentPaneProductRulesTests.Rig()
            try await rig.start()
            defer { rig.server.stop() }
            let userHome = rig.folder("home")
            let folder = terminal == "/" ? "/" : userHome
            // What `agentSeedFromSelectedTab` gives: the selected terminal's cwd, no New Tab page.
            let model = AgentPaneModel(host: MockAgentPaneHost(), seed: AgentPaneSeedSource(AgentPaneSeed(cwd: folder)),
                                       transport: rig.transport)
            rig.transport.homeFolder = userHome
            let home = AgentHome(base: rig.folder("support") + "/cmux/agent-home")
            model.workspaceRoots = { [folder] }
            model.workspaceAgentHome = { AgentHomeFill(home: home, workspace: "ws-terminal") }
            model.onChooseFolder = { .cancelled }
            let handshake = await model.respond(to: .ready)["value"] as? [String: Any]
            #expect(handshake?["cwd"] == nil, "the page got \(folder) as the chat folder")
            #expect(handshake?["chooseFolder"] as? Bool == true)
            #expect(model.transport.primaryRoot() == nil)
            // The page's first chat (no cwd): agent-home, never the terminal's folder.
            let chat = await rig.send("session/new", ["mcpServers": [Any]()])
            #expect(await rig.cwd(chat) == home.base + "/ws-terminal")
            // A page that names the folder itself is refused: it is no root.
            await rig.send("session/new", ["cwd": folder, "mcpServers": [Any]()], expect: .pathOutsideRoots)
            await rig.send("session/new", ["cwd": "/", "mcpServers": [Any]()], expect: .pathOutsideRoots)
        }
    }

    @Test func theModelGivesItsTransportTheWorkspaceAgentHome() throws {
        let model = AgentPaneModel(host: MockAgentPaneHost())
        let home = AgentHome(base: try base())
        model.workspaceRoots = { [] }
        model.workspaceAgentHome = { AgentHomeFill(home: home, workspace: "ws-model") }
        #expect(model.transport.agentHome() == AgentHomeFill(home: home, workspace: "ws-model"))
        #expect(model.transport.primaryRoot() == nil)
    }
}
