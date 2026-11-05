public import Foundation

/// One line of a workspace hover card's timeline (u3320, Lawrence 2026-10-19: "I want to see the
/// history of prompts that were sent, as well as when they were sent and when Codex completed. I
/// want to know when Claude started waiting for my input"). The App reads them from the daemon's
/// per-terminal timelines and the acpmux mirror when a card opens (`SidebarTimelineSource`).
public nonisolated struct SidebarTimelineEntry: Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable, CaseIterable {
        /// The person sent a prompt (its text when known).
        case prompt
        /// An agent started working with no prompt known.
        case started
        /// An agent waited for the person (a permission, a question).
        case waiting
        /// An agent finished its turn and waited for the next prompt.
        case finished
        /// A turn failed, or the agent went away before it answered.
        case failed
    }

    public var kind: Kind
    public var date: Date
    /// The prompt, or why the agent waits; nil when unknown.
    public var text: String?
    /// The agent's display name ("Claude Code", "Codex"); nil when unknown.
    public var agent: String?
    /// A turn acpmux's notice of other agents' messages started ("[inbox] New messages…"), not
    /// the person: the card's stats count its work, its History lists it not.
    public var isNotice: Bool

    public init(kind: Kind, date: Date, text: String? = nil, agent: String? = nil, isNotice: Bool = false) {
        self.kind = kind
        self.date = date
        self.text = text
        self.agent = agent
        self.isNotice = isNotice
    }
}

/// The workspace timeline a card shows, newest first, at most `limit` entries; the App injects one.
public typealias SidebarTimelineSource = @MainActor (_ workspace: WorkspaceID, _ limit: Int) -> [SidebarTimelineEntry]
