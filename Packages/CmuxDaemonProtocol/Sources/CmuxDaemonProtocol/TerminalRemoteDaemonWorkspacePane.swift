public import Foundation

/// A single pane within a daemon workspace.
///
/// Carried inside ``TerminalRemoteDaemonWorkspaceEntry`` to describe each pane's
/// backing session, title, and working directory.
public struct TerminalRemoteDaemonWorkspacePane: Decodable, Equatable, Sendable {
    /// The pane identifier.
    public let id: String
    /// The session backing the pane, if any.
    public let sessionID: String?
    /// The pane title, if set.
    public let title: String?
    /// The pane's working directory, if known.
    public let directory: String?

    /// Creates a workspace pane value.
    /// - Parameters:
    ///   - id: The pane identifier.
    ///   - sessionID: The backing session, if any.
    ///   - title: The pane title, if set.
    ///   - directory: The working directory, if known.
    public init(
        id: String,
        sessionID: String? = nil,
        title: String? = nil,
        directory: String? = nil
    ) {
        self.id = id
        self.sessionID = sessionID
        self.title = title
        self.directory = directory
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case sessionID = "session_id"
        case title
        case directory
    }
}
