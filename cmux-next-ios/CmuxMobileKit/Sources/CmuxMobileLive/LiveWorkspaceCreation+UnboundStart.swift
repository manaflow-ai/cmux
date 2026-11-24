import CmuxMobileAgentChat
import CmuxMobileModel
import Foundation

/// An agent tab the Mac made that has no chat yet (a New Agent Chat tab nobody wrote in) gets its
/// chat from the phone's first send, in that tab (Leo, 2026-11-18: "you should be able to just
/// start the chat right there"). The same start as the phone's New Agent Chat
/// (``startAgentSession(_:cwd:macID:)``: `session/new` with policy `ask`, in the tab's folder),
/// then the tab takes the session with `bind-conversation-tab-session` from no session
/// (`expected_session` null: a chat the Mac or another phone started first wins). The first
/// message then goes through the bound chat's own source (LiveCoordinator), so a failure to send
/// it hands the draft back in the chat on screen.
extension LiveWorkspaceCreationBackend {
    /// Starts tab `tabID`'s chat and binds the tab to it; returns the session. Throws, with
    /// nothing bound, when the chat could not start or the tab took another chat first.
    func startUnboundChat(tabID: String, harness: String?) async throws -> String {
        guard let client = sync.daemon, let tree = sync.tree, let surface = tree.surfaces[tabID] else {
            throw WorkspaceCreationError("This tab isn't on the Mac anymore.", isForPerson: true)
        }
        let binding = tree.agentTabs[tabID]
        guard binding?.session == nil else {
            throw WorkspaceCreationError("This tab has a chat now. Send again once it loads.", isForPerson: true)
        }
        // Only a chat of this Mac: a tab whose chat another machine starts (`registry:`, `machine:`) starts there.
        guard Self.startsHere(host: binding?.host) else {
            throw WorkspaceCreationError("This chat runs on another machine. Start it from cmux on that machine.", isForPerson: true)
        }
        let cwd = try Self.unboundChatFolder(tabID: tabID, in: tree)
        let macID = sync.macID.isEmpty ? (link.target?.macID ?? "") : sync.macID
        // The tab's own agent, as the Mac recorded it; else the one the chat names, else the Mac's default.
        let start = AgentChatStart(harness: [binding?.harness, harness].compactMap { $0 }.first { !$0.isEmpty })
        let (_, session) = try await startAgentSession(start, cwd: cwd, macID: macID)
        do {
            // No harness: the tab keeps the agent the Mac recorded (the phone's lane refuses one).
            try WorkspaceSync.check(await client.request(Self.bindCommand, params: [
                "surface": surface, "session": session, "expected_session": NSNull(),
            ]))
        } catch let error as DaemonReplyError {
            // The session stays in acpmux's list, unbound, like a chat whose tab closed.
            throw WorkspaceCreationError(error.message.contains("session_conflict")
                ? "This tab started a chat on the Mac first. Send again once it loads." : error.message, isForPerson: true)
        }
        return session
    }

    /// `bind-conversation-tab-session`: the phone's lane allows it only from no session (cmux-mobile-host policy).
    nonisolated static let bindCommand = "bind-conversation-tab-session"

    /// Whether a tab recorded for `host` starts its chat on this Mac's acpmux: the Mac app's own
    /// `install:<id>` (the host a phone's agent tab gets too), or none recorded.
    nonisolated static func startsHere(host: String?) -> Bool {
        guard let host, !host.isEmpty else { return true }
        return host.hasPrefix("install:")
    }

    /// The folder the tab's chat starts in: the tab's own, else its workspace's first (as a new
    /// agent tab of that workspace starts); never the home folder or above.
    nonisolated static func unboundChatFolder(tabID: String, in tree: DaemonTree) throws -> String {
        let workspace = (tree.workspaces + tree.homeWorkspaces).first { $0.tabs.contains { $0.id == tabID } }
        let cwd = tree.directories[tabID] ?? workspace?.tabs.lazy.compactMap { tree.directories[$0.id] }.first
        guard let cwd, !isHomeOrAbove(cwd) else {
            throw WorkspaceCreationError("Agent chats start in a project folder. Open this workspace in a project folder on the Mac.",
                                         isForPerson: true)
        }
        return cwd
    }
}
