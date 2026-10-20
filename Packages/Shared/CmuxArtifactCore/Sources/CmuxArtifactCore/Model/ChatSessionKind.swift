import Foundation

/// What kind of session a chat surface is showing.
///
/// Agent sessions render as a request/response conversation (opposing
/// bubbles, prose markdown); terminal sessions render as a single-column
/// monospace command log. The surface branches its chrome (composer
/// placeholder, input font) on this, and the transcript rows differ by kind.
public enum ChatSessionKind: String, Sendable, Equatable, Codable {
    /// A coding-agent conversation (Claude, Codex, …).
    case agent
    /// A plain terminal/shell session rendered as a command log.
    case terminal
}
