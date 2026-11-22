import Foundation
import Testing
@testable import CmuxNextAgentPane

/// hq5cah live check (cmux-lawrence-2, 04-terminal.png): after the first chat in a folderless
/// workspace, a new terminal opened from that chat started in the chat's agent-home folder, and
/// the sidebar then showed that path as the workspace's folder. Lead decision: agent-home is ONLY
/// the folder of agent chats. A terminal opened from the chat keeps its own default (the user's
/// shell default, `~`), and an agent-home folder never counts as the workspace's folder.
@MainActor
@Suite struct AgentHomeOtherTabsTests {
    static let home = AgentHome(base: "/Users/me/Library/Application Support/cmux/agent-home")
    static let folder = home.base + "/ws-1"

    static func model(seed: AgentPaneSeedSource? = nil) -> AgentPaneModel {
        let model = AgentPaneModel(host: MockAgentPaneHost(), seed: seed)
        model.workspaceRoots = { [] }
        model.workspaceAgentHome = { AgentHomeFill(home: home, workspace: "ws-1") }
        model.onChooseFolder = { .cancelled }
        return model
    }

    /// The chat header's Terminal button (`pane.action splitRight`) names the chat's folder: for an
    /// agent-home folder the split opens in the home folder (temporary, until the shared resolver
    /// NEW-TERMINAL-INHERITS-CWD lands), never in agent-home and never with no folder (`/` after a
    /// Dock launch); a project folder passes unchanged.
    @Test func theHeaderTerminalOpensInTheHomeFolderNeverInAgentHome() async {
        let model = Self.model()
        model.transport.homeFolder = "/Users/me"
        var ran: [String] = []
        model.header = AgentPaneHeaderHooks(run: { id, cwd in ran.append("\(id)@\(cwd ?? "none")") }, tabState: { [:] })
        _ = await model.respond(to: .paneAction("splitRight", cwd: Self.folder))
        _ = await model.respond(to: .paneAction("splitRight", cwd: Self.folder + "/notes"))
        _ = await model.respond(to: .paneAction("splitRight", cwd: "/Users/me/project"))
        #expect(ran == ["splitRight@/Users/me", "splitRight@/Users/me", "splitRight@/Users/me/project"])
    }

    /// New Terminal Tab from the chat starts in the chat's `pane.context` cwd (#16620), which
    /// passes through the same gate: the home folder for agent-home, never agent-home, never `/`.
    @Test func newTerminalTabFromTheChatGetsTheHomeFolderNeverAgentHome() {
        let model = Self.model()
        model.transport.homeFolder = "/Users/me"
        for cwd in [Self.folder, Self.folder + "/notes", Self.home.base] {
            let start = model.folderForOtherTabs(cwd)
            #expect(start == "/Users/me", "\(cwd) gave \(start ?? "no folder")")
            #expect(start != "/")
        }
        #expect(model.folderForOtherTabs("/Users/me/project") == "/Users/me/project")
        #expect(model.folderForOtherTabs(nil) == nil)
    }

    /// A terminal that is in agent-home anyway (the user went there) is no workspace folder: the
    /// next new chat still starts in agent-home, and the page still offers Choose Folder….
    @Test func aTerminalInAgentHomeIsNoWorkspaceFolder() async throws {
        let model = Self.model()
        model.workspaceRoots = { [Self.folder] }
        let handshake = try #require(await model.respond(to: .ready)["value"] as? [String: Any])
        #expect(handshake["chooseFolder"] as? Bool == true, "the page lost Choose Folder… to a terminal in agent-home")
        #expect(model.transport.primaryRoot() == nil)
    }

    /// New Agent Chat from such a terminal inherits no agent-home folder as its seed either.
    @Test func aSeedInAgentHomeIsNoChatFolder() async throws {
        let model = Self.model(seed: AgentPaneSeedSource(AgentPaneSeed(cwd: Self.folder)))
        let handshake = try #require(await model.respond(to: .ready)["value"] as? [String: Any])
        #expect(handshake["cwd"] == nil)
        #expect(handshake["chooseFolder"] as? Bool == true)
    }
}
