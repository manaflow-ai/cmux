import Foundation

/// The Codex lifecycle states that affect terminal-tab presentation.
public enum CodexTabTitleLifecycle: String, Equatable, Sendable {
    /// A Codex turn is actively executing.
    case running
    /// A Codex turn completed and the session is waiting at its prompt.
    case idle
    /// Codex is waiting for user input such as permission or clarification.
    case needsInput
    /// The lifecycle source has not established a more precise state.
    case unknown
}
