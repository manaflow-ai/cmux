/// The author of a ``ChatMessage`` within an agent or terminal conversation.
public enum ChatRole: String, Sendable, Equatable, Codable {
    /// The human operating the session (prompts, answers, attachments).
    case user
    /// The coding agent (prose, tool runs, edits, questions).
    case agent
    /// The session itself (lifecycle transitions, connection changes).
    case system
}
