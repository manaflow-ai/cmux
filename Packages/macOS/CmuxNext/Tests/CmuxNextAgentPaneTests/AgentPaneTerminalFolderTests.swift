@testable import CmuxNextAgentPane
import Foundation
import Testing
import CmuxNextWakeups

/// A terminal opened from an agent chat (Cmd-D, Cmd-T, Cmd-N, the header's Terminal, a shell
/// block's Open in Terminal) starts in the chat's exact folder. The daemon records no folder for a
/// chat tab, so the App reads it from the pane: the folder acpmux reported for the chat's session.
@MainActor
struct AgentPaneTerminalFolderTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    private static func folder() throws -> String {
        let path = FileManager.default.temporaryDirectory.appending(path: "terminal-folder-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    /// A restored chat whose session runs in a worktree: its terminals start there, before the
    /// page has said anything.
    @Test func aChatsTerminalStartsInItsSessionFolder() throws {
        let worktree = try Self.folder()
        let chat = AgentPaneModel(runner: BackgroundWork(label: "test.agent-pane"), host: NoHost(), sessionId: "s")
        chat.transport.sessions.observeFolder(["result": ["session": ["sessionId": "s", "cwd": worktree]]], replyTo: "_acpmux/attach")
        #expect(chat.terminalFolder == worktree)
    }

    /// A new chat's `session/new` reply names its folder the same way.
    @Test func aNewChatsTerminalStartsInTheFolderItStartedIn() throws {
        let project = try Self.folder()
        let chat = AgentPaneModel(runner: BackgroundWork(label: "test.agent-pane"), host: NoHost(), sessionId: "n")
        chat.transport.sessions.observeFolder(["result": ["sessionId": "n", "_meta": ["acpmux": ["cwd": project]]]], replyTo: "session/new")
        #expect(chat.terminalFolder == project)
    }

    /// Agent-home is the chat's own folder, never a terminal's: no folder, the daemon decides.
    @Test func anAgentHomeChatNamesNoFolder() throws {
        let base = try Self.folder()
        let home = AgentHome(base: base)
        let chat = AgentPaneModel(runner: BackgroundWork(label: "test.agent-pane"), host: NoHost(), sessionId: "h")
        chat.workspaceAgentHome = { AgentHomeFill(home: home, workspace: "w") }
        chat.transport.sessions.observeFolder(["result": ["session": ["sessionId": "h", "cwd": base + "/w"]]], replyTo: "_acpmux/attach")
        #expect(chat.terminalFolder == nil)
    }
}
