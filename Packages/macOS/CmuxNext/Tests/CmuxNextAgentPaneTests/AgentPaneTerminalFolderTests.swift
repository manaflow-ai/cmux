@testable import CmuxNextAgentPane
import Foundation
import Testing

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
        let chat = AgentPaneModel(host: NoHost(), sessionId: "s")
        chat.transport.sessions.observeFolder(["result": ["session": ["sessionId": "s", "cwd": worktree]]], replyTo: "_acpmux/attach")
        #expect(chat.terminalFolder == worktree)
    }

    /// A new chat's `session/new` reply names its folder the same way.
    @Test func aNewChatsTerminalStartsInTheFolderItStartedIn() throws {
        let project = try Self.folder()
        let chat = AgentPaneModel(host: NoHost(), sessionId: "n")
        chat.transport.sessions.observeFolder(["result": ["sessionId": "n", "_meta": ["acpmux": ["cwd": project]]]], replyTo: "session/new")
        #expect(chat.terminalFolder == project)
    }

    /// Agent-home is the chat's own folder, never a terminal's: no folder, the daemon decides.
    @Test func anAgentHomeChatNamesNoFolder() throws {
        let base = try Self.folder()
        let home = AgentHome(base: base)
        let chat = AgentPaneModel(host: NoHost(), sessionId: "h")
        chat.workspaceAgentHome = { AgentHomeFill(home: home, workspace: "w") }
        chat.transport.sessions.observeFolder(["result": ["session": ["sessionId": "h", "cwd": base + "/w"]]], replyTo: "_acpmux/attach")
        #expect(chat.terminalFolder == nil)
    }

    /// Ctrl-` (and every other terminal from the chat) after the person picks a project on the
    /// New Tab page's folder chip, before the first send (`workspace.useFolder`): the terminal
    /// starts in the pick, not in the folder the page opened with (#22225, #22230).
    @Test func aTerminalBeforeTheFirstSendStartsInThePickedProject() async throws {
        let opened = try Self.folder()
        let picked = try Self.folder()
        let chat = AgentPaneModel(host: NoHost())
        chat.transport.homeFolder = "/nonexistent-home-\(UUID().uuidString)"
        chat.startFolders.resolve = { proposed in AgentPaneStartFolder(kind: .seed, cwd: proposed, agentHome: nil) }
        chat.handshakeCwd = opened
        #expect(chat.terminalFolder == opened)

        chat.transport.gestures.record(click: true) // the click on the project in the chip's menu
        _ = await chat.respond(to: .useFolder(picked, confirm: false))
        #expect(chat.terminalFolder.map(Self.canonical) == Self.canonical(picked))
    }

    /// A page script's pick of a folder the pane may not use, with no person behind it, never
    /// moves where a terminal starts.
    @Test func aPickWithoutThePersonLeavesTheTerminalFolder() async throws {
        let opened = try Self.folder()
        let elsewhere = try Self.folder()
        let chat = AgentPaneModel(host: NoHost())
        chat.transport.homeFolder = "/nonexistent-home-\(UUID().uuidString)"
        chat.startFolders.resolve = { proposed in AgentPaneStartFolder(kind: .seed, cwd: proposed, agentHome: nil) }
        chat.handshakeCwd = opened
        _ = await chat.respond(to: .useFolder(elsewhere, confirm: false))
        #expect(chat.terminalFolder == opened)
    }

    /// Switching the chip from a project to agent-home: the terminal gets no folder again, not the project.
    @Test func anAgentHomePickAfterAProjectNamesNoFolder() async throws {
        let base = try Self.folder()
        let project = try Self.folder()
        let home = AgentHome(base: base)
        let chat = AgentPaneModel(host: NoHost())
        chat.transport.homeFolder = "/nonexistent-home-\(UUID().uuidString)"
        chat.workspaceAgentHome = { AgentHomeFill(home: home, workspace: "w") }
        chat.startFolders.resolve = { proposed in
            proposed == base + "/w" ? AgentPaneStartFolder(kind: .agentHome, cwd: nil, agentHome: proposed)
                : AgentPaneStartFolder(kind: .seed, cwd: proposed, agentHome: nil)
        }
        chat.transport.gestures.record(click: true)
        _ = await chat.respond(to: .useFolder(project, confirm: false))
        #expect(chat.terminalFolder != nil)
        _ = await chat.respond(to: .useFolder(base + "/w", confirm: false))
        #expect(chat.terminalFolder == nil)
    }

    /// A later pick the pane may not use (its click already spent) drops the earlier project: the
    /// terminal starts in the pane's own folder, not in a project the chip no longer shows.
    @Test func aLaterPickThePaneMayNotUseDropsTheEarlierProject() async throws {
        let opened = try Self.folder()
        let first = try Self.folder()
        let second = try Self.folder()
        let chat = AgentPaneModel(host: NoHost())
        chat.transport.homeFolder = "/nonexistent-home-\(UUID().uuidString)"
        chat.startFolders.resolve = { proposed in AgentPaneStartFolder(kind: .seed, cwd: proposed, agentHome: nil) }
        chat.handshakeCwd = opened
        chat.transport.gestures.record(click: true)
        _ = await chat.respond(to: .useFolder(first, confirm: false))
        #expect(chat.terminalFolder.map(Self.canonical) == Self.canonical(first))

        _ = await chat.respond(to: .useFolder(second, confirm: false)) // no click left to grant it
        #expect(chat.terminalFolder == opened)
    }

    /// Two picks whose replies come back in the other order: the later pick stays the terminal's folder.
    @Test func aPickThatFinishesAfterALaterPickChangesNothing() async throws {
        let earlier = try Self.folder()
        let later = try Self.folder()
        let chat = AgentPaneModel(host: NoHost())
        chat.transport.roots = { [earlier, later] }
        let first = chat.beginPick()
        let second = chat.beginPick()
        _ = await chat.notePicked(second, Self.ok(later))
        _ = await chat.notePicked(first, Self.ok(earlier))
        #expect(chat.terminalFolder == later)
    }

    private static func ok(_ cwd: String) -> [String: Any] { AgentPaneReply.success(["status": "ok", "cwd": cwd]) }

    private static func canonical(_ path: String) -> String { AcpmuxPathPolicy.canonical(path) ?? path }
}
