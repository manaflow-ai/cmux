import Foundation

/// One moment in an agent's history (u3320, the workspace hover card's timeline): a prompt the
/// person sent, a turn that started without one, a wait for the person, a finished or failed turn.
public struct AgentTimelineEvent: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable, CaseIterable {
        /// The person sent a prompt; the turn it starts is implied.
        case prompt
        /// The agent started working with no prompt known (another reporter, a resumed chat).
        case started
        /// The agent waits for the person: a permission, a question.
        case waiting
        /// The turn finished; the agent waits for the next prompt.
        case finished
        /// The turn failed, or the agent went away before it answered.
        case failed
    }

    public var kind: Kind
    /// When it happened (Unix ms).
    public var atMs: UInt64
    /// The prompt's text (at most `AgentTimeline.textLimit` characters), or why the agent waits.
    public var text: String?
    /// The agent's name when known ("claude", "codex").
    public var agent: String?
    /// A turn acpmux's own notice started (other agents' messages arrived), not a prompt anyone
    /// typed: its work counts, but a History of what was asked leaves it out.
    public var isNotice = false

    public init(kind: Kind, atMs: UInt64, text: String? = nil, agent: String? = nil, isNotice: Bool = false) {
        self.kind = kind
        self.atMs = atMs
        self.text = text
        self.agent = agent
        self.isNotice = isNotice
    }
}
