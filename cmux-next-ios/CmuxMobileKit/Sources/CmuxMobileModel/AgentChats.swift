import Foundation

/// One agent chat the Mac's acpmux knows (`_acpmux/sessions`), as the Chats list shows it.
public struct AgentChatListing: Identifiable, Hashable, Sendable {
    /// acpmux's session id.
    public var id: String
    /// The chat's title, nil before it has one (the list then says "New chat", as the Mac does).
    public var title: String?
    /// The harness id (`claude`, `codex`), what a tab of it names.
    public var harness: String
    /// The chat's folder on the Mac (absolute).
    public var cwd: String
    /// acpmux's status: `idle`, `ready`, `running`, `waiting`, `disconnected` or `closed`.
    public var status: String
    public var updatedAt: Date?
    /// Archived on the Mac (the `archived` tag): the lists hide it until it is unarchived.
    public var archived: Bool
    /// The last prompt, for search and the row's second line.
    public var lastPrompt: String?

    public init(id: String, title: String?, harness: String, cwd: String, status: String, updatedAt: Date?,
                archived: Bool, lastPrompt: String? = nil) {
        self.id = id
        self.title = title
        self.harness = harness
        self.cwd = cwd
        self.status = status
        self.updatedAt = updatedAt
        self.archived = archived
        self.lastPrompt = lastPrompt
    }

    /// The title the list shows (the Mac's `handlers.agentChats.untitled`).
    public var displayTitle: String {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "New chat" : trimmed
    }

    /// Working now, or waiting on the person.
    public var isActive: Bool { status == "running" || status == "waiting" }
}

/// One page of the Mac's chats, newest first, and the cursor of the next page (nil: the end).
public struct AgentChatPage: Hashable, Sendable {
    public var chats: [AgentChatListing]
    public var nextCursor: String?

    public init(chats: [AgentChatListing], nextCursor: String?) {
        self.chats = chats
        self.nextCursor = nextCursor
    }
}

/// Which chats the list shows: the Mac's lists (archived hidden), or its archived ones.
public enum AgentChatScope: String, CaseIterable, Hashable, Sendable {
    case chats = "Chats"
    case archived = "Archived"
}

extension AgentChatListing {
    /// The chats of `scope` that match `query`, in the given (newest first) order. A query
    /// matches the title, the folder, the agent and the last prompt, as the Mac's chats page
    /// searches title, folder and harness; every word must match (case and accents ignored).
    public static func filter(_ chats: [AgentChatListing], scope: AgentChatScope, query: String) -> [AgentChatListing] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        return chats.filter { chat in
            guard chat.archived == (scope == .archived) else { return false }
            guard !words.isEmpty else { return true }
            let haystack = [chat.displayTitle, chat.cwd, chat.harness, chat.lastPrompt ?? ""].joined(separator: "\n")
            return words.allSatisfy { haystack.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
    }
}

/// The Mac's agent chats on a phone: the Chats list (Search Agent Chats), opening one in a
/// tab or a new workspace (Open Agent Session in Tab / in New Workspace), Archive and
/// Unarchive, and Open Chat Folder in Terminal.
@MainActor
public protocol AgentChatsBackend: AnyObject {
    /// Whether the Mac's chats can be listed now (linked, acpmux ready).
    func canListAgentChats(on macID: String) -> Bool
    /// A page of the Mac's chats, newest first (`cursor`: a previous page's `nextCursor`).
    func agentChats(on macID: String, cursor: String?) async throws -> AgentChatPage
    /// The chat as a tab of `workspace`: the tab already showing it there, else a new one in
    /// the workspace's active pane. Returns the tab once the Mac lists it.
    func openAgentChat(_ chat: AgentChatListing, in workspace: Workspace) async throws -> WorkspaceTab
    /// A new workspace whose only tab is the chat. Returns it once the Mac lists it.
    func openAgentChatInNewWorkspace(_ chat: AgentChatListing, on macID: String) async throws -> Workspace
    /// Archive (true) or Unarchive (false) on the Mac; returns the chat as the Mac has it now.
    func setAgentChatArchived(_ chat: AgentChatListing, archived: Bool, on macID: String) async throws -> AgentChatListing
    /// Open Chat Folder in Terminal: a new terminal tab beside the chat's tab, in the chat's
    /// folder. Returns it once the Mac lists it.
    func openChatFolderInTerminal(_ tab: WorkspaceTab, in workspace: Workspace) async throws -> WorkspaceTab
}
