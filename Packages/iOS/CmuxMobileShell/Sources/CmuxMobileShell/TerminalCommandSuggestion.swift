import Foundation

/// A complete suggested command from the original transcript of one bound Claude session.
public struct TerminalCommandSuggestion: Identifiable, Equatable, Sendable {
    /// Stable identity for a command in its source session.
    public var id: String { sessionID + "\n" + text }
    /// The Claude session whose message suggested this command.
    public let sessionID: String
    /// Exact command text, including its bang prefix and real script newlines.
    public let text: String
}
