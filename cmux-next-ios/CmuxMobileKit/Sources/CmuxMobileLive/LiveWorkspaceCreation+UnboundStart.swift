import CmuxMobileAgentChat
import CmuxMobileModel
import Foundation

/// The first send of an agent tab the Mac made that has no chat yet (a New Agent Chat tab nobody
/// wrote in) starts its chat from the phone, in that tab (Leo, 2026-11-18: "you should be able to
/// just start the chat right there"). The same start as the phone's New Agent Chat
/// (``startAgentSession(_:cwd:macID:)``: `session/new` with policy `ask`, in the tab's folder),
/// then the tab takes the session with `bind-conversation-tab-session` from no session
/// (`expected_session` null: a chat the Mac or another phone started first wins, and this send's
/// draft comes back), then the prompt, as New Task's first message is sent.
extension LiveWorkspaceCreationBackend {
    /// Starts tab `tabID`'s chat with `text` and `attachments` as its first message. Throws, with
    /// nothing sent, when the chat could not start or the tab took another chat first; a prompt
    /// that fails after the start goes to `failed`, as New Task's does.
    func startUnboundChat(tabID: String, harness: String?, text: String, attachments: [AgentAttachment],
                          failed: @escaping @MainActor (TaskDeliveryFailure) -> Void) async throws {
        guard let client = sync.daemon, let tree = sync.tree, let surface = tree.surfaces[tabID] else {
            throw WorkspaceCreationError("This tab isn't on the Mac anymore.", isForPerson: true)
        }
        guard tree.agentTabs[tabID]?.session == nil else {
            throw WorkspaceCreationError("This tab has a chat now. Send again once it loads.", isForPerson: true)
        }
        let cwd = try Self.unboundChatFolder(tabID: tabID, in: tree)
        let macID = sync.macID ?? link.target?.macID ?? ""
        let (harness, session) = try await startAgentSession(AgentChatStart(harness: harness?.nilIfEmpty), cwd: cwd, macID: macID)
        do {
            try WorkspaceSync.check(await client.request(Self.bindCommand, params: [
                "surface": surface, "session": session, "expected_session": NSNull(), "harness": harness,
            ]))
        } catch let error as DaemonReplyError {
            // The session stays in acpmux's list, unbound, like a chat whose tab closed.
            throw WorkspaceCreationError(error.message.contains("session_conflict")
                ? "This tab started a chat on the Mac first. Send again once it loads." : error.message, isForPerson: true)
        }
        taskSessions[Self.unboundKey(tabID)] = (session, cwd)
        let task = AgentTask(prompt: text, images: attachments.filter { $0.kind == .image }.map { AgentTaskImage(id: $0.id, data: $0.data) },
                             files: attachments.filter { $0.kind != .image }.map { AgentTaskFile(id: $0.id, name: $0.name, data: $0.data) })
        try sendTask(task, in: Self.unboundKey(tabID), failed: failed)
    }

    /// `bind-conversation-tab-session`: the phone's lane allows it only from no session (cmux-mobile-host policy).
    nonisolated static let bindCommand = "bind-conversation-tab-session"

    /// The key ``sendTask(_:in:failed:)`` finds the started chat by, apart from New Task's workspace keys.
    nonisolated static func unboundKey(_ tabID: String) -> String { "unbound-tab:\(tabID)" }

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

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
