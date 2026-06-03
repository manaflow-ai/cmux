public import Foundation

/// A single terminal pane within a ``TerminalWorkspace``.
public struct TerminalPane: Codable, Equatable, Sendable, Identifiable {
    /// The pane identifier.
    public let id: String
    /// The terminal session identifier backing this pane, if attached.
    public var sessionID: String?
    /// The pane title.
    public var title: String
    /// The working directory the pane is in.
    public var directory: String

    /// Creates a terminal pane.
    /// - Parameters:
    ///   - id: The pane identifier.
    ///   - sessionID: The backing session identifier, if any.
    ///   - title: The pane title.
    ///   - directory: The working directory.
    public init(id: String, sessionID: String? = nil, title: String, directory: String) {
        self.id = id
        self.sessionID = sessionID
        self.title = title
        self.directory = directory
    }
}
