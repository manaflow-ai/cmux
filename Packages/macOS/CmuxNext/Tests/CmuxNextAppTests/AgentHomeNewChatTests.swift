import CmuxNextActions
@testable import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextDaemon
import Foundation
import Testing

/// nxdog62 (2d88394fdea2, cmux-lawrence-2): New Agent Chat (palette.newAgentChat, Cmd-I) in a
/// workspace whose only folder is the home folder (its terminal tab sits at `~`) started Claude
/// Code in `~`. The app seeded the chat with the terminal's cwd, and the store's workspace roots
/// held `~`. AGENT-CWD-FOR-FOLDERLESS-WORKSPACE: such a workspace has no folder; its new chat gets
/// no `~` or `/` as its cwd, starts in the workspace's agent-home, and the page offers Choose
/// Folder….
@MainActor
@Suite struct AgentHomeNewChatTests {
    @Test(arguments: [NSHomeDirectory(), "/"])
    func aNewChatFromATerminalAtTheHomeFolderGetsAgentHomeNeverTheFolder(_ folder: String) async throws {
        let fixture = try AgentTabFixture(terminalCwd: folder)
        // The seed palette.newAgentChat gives from that terminal (`agentSeedFromSelectedTab`).
        let key = try await fixture.open(seed: AgentPaneSeedSource(AgentPaneSeed(cwd: folder)))
        let view = try #require(fixture.tabs.view(for: key))
        #expect(fixture.tabs.workspaceRoots(of: key) == [folder], "the terminal's folder is the workspace's only one")
        let handshake = try #require(await view.model.respond(to: .ready)["value"] as? [String: Any])
        #expect(handshake["cwd"] == nil, "the page got \(folder) as the chat folder")
        #expect(handshake["chooseFolder"] as? Bool == true, "the page offers Choose Folder…")
        // The relay's fill for a `session/new` without a cwd: no workspace root, so agent-home.
        #expect(view.model.transport.primaryRoot() == nil)
        let fill = try #require(view.model.transport.agentHome())
        let workspace = try #require(fixture.daemon.workspaces.first)
        #expect(fill.workspace == workspace.id)
        let path = try #require(fill.home.path(for: fill.workspace))
        #expect(path.hasSuffix("/Library/Application Support/cmux/agent-home/\(workspace.id)"))
        #expect(!AgentHome.isHomeOrAbove(path))
    }

    /// A workspace with a real folder keeps it: the chat starts there, with no Choose Folder offer.
    @Test func aNewChatFromATerminalInAProjectStartsThere() async throws {
        let project = FileManager.default.temporaryDirectory.appendingPathComponent("agent-home-project-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: project) }
        let fixture = try AgentTabFixture(terminalCwd: project)
        let key = try await fixture.open(seed: AgentPaneSeedSource(AgentPaneSeed(cwd: project)))
        let view = try #require(fixture.tabs.view(for: key))
        let handshake = try #require(await view.model.respond(to: .ready)["value"] as? [String: Any])
        #expect(handshake["cwd"] as? String == project)
        #expect(handshake["chooseFolder"] == nil)
        #expect(view.model.transport.primaryRoot() == project)
    }

    /// hq5cah live check (cmux-lawrence-2, 04-terminal.png): in a folderless workspace (its
    /// terminal at `~`), the first chat runs in agent-home; a terminal opened from that chat (its
    /// header's Terminal split) started in agent-home too, and the sidebar then showed that path.
    /// Agent-home is only the chat's folder: the split opens in `~` (temporary, until the shared
    /// resolver NEW-TERMINAL-INHERITS-CWD lands), never in agent-home and never in `/`, and the
    /// workspace keeps no agent-home folder, so the next chat still offers Choose Folder….
    @Test func aTerminalFromAnAgentHomeChatKeepsItsOwnDefaultFolder() async throws {
        let registry = ActionRegistry()
        let asked = SplitRequests()
        registry.register(Action(id: "splitRight", title: "Split Right", invoke: { asked.cwds.append($0["cwd"]?.stringValue) }, handler: {}))
        let fixture = try AgentTabFixture(registry: registry, terminalCwd: NSHomeDirectory())
        let key = try await fixture.open()
        let view = try #require(fixture.tabs.view(for: key))
        let handshake = try #require(await view.model.respond(to: .ready)["value"] as? [String: Any])
        #expect(handshake["chooseFolder"] as? Bool == true)
        let fill = try #require(view.model.transport.agentHome())
        let agentHome = try #require(fill.home.path(for: fill.workspace))

        let reply = await view.model.respond(to: .paneAction("splitRight", cwd: agentHome))
        #expect(reply["ok"] as? Bool == true)
        #expect(asked.cwds.count == 1)
        #expect(asked.cwds.first == .some(NSHomeDirectory()), "the terminal split started in \(asked.cwds.first.flatMap { $0 } ?? "no folder")")
        #expect(!fixture.tabs.workspaceRoots(of: key).contains(agentHome))
        #expect(view.model.transport.primaryRoot() == nil)
    }
}

/// The `cwd` of each `splitRight` the chat header ran.
@MainActor final class SplitRequests {
    var cwds: [String?] = []
}
