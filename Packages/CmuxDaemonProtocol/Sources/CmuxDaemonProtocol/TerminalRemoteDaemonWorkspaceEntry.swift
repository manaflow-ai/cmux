public import Foundation

/// A single workspace as reported by the daemon.
///
/// Carried inside ``TerminalRemoteDaemonWorkspaceListResult`` and the workspace
/// push snapshots. Describes the workspace's identity, focus, activity, and panes.
public struct TerminalRemoteDaemonWorkspaceEntry: Decodable, Equatable, Sendable {
    /// The workspace identifier.
    public let id: String
    /// The workspace title.
    public let title: String
    /// The workspace's working directory.
    public let directory: String
    /// The currently focused pane, if any.
    public let focusedPaneID: String?
    /// The number of panes in the workspace.
    public let paneCount: Int
    /// The workspace creation time (epoch milliseconds).
    public let createdAt: Int64
    /// The time of the workspace's last activity (epoch milliseconds).
    public let lastActivityAt: Int64
    /// A representative session for the workspace, if any.
    public let sessionID: String?
    /// A short preview of recent output, if available.
    public let preview: String?
    /// The number of unread items, if reported.
    public let unreadCount: Int?
    /// Whether the workspace is pinned, if reported.
    public let pinned: Bool?
    /// The workspace's panes, if reported.
    public let panes: [TerminalRemoteDaemonWorkspacePane]?

    /// Creates a workspace entry value.
    /// - Parameters:
    ///   - id: The workspace identifier.
    ///   - title: The workspace title.
    ///   - directory: The working directory.
    ///   - focusedPaneID: The focused pane, if any.
    ///   - paneCount: The number of panes.
    ///   - createdAt: The creation time (epoch milliseconds).
    ///   - lastActivityAt: The last-activity time (epoch milliseconds).
    ///   - sessionID: A representative session, if any.
    ///   - preview: A short output preview, if available.
    ///   - unreadCount: The unread count, if reported.
    ///   - pinned: Whether the workspace is pinned, if reported.
    ///   - panes: The workspace's panes, if reported.
    public init(
        id: String,
        title: String,
        directory: String,
        focusedPaneID: String? = nil,
        paneCount: Int,
        createdAt: Int64,
        lastActivityAt: Int64,
        sessionID: String? = nil,
        preview: String? = nil,
        unreadCount: Int? = nil,
        pinned: Bool? = nil,
        panes: [TerminalRemoteDaemonWorkspacePane]? = nil
    ) {
        self.id = id
        self.title = title
        self.directory = directory
        self.focusedPaneID = focusedPaneID
        self.paneCount = paneCount
        self.createdAt = createdAt
        self.lastActivityAt = lastActivityAt
        self.sessionID = sessionID
        self.preview = preview
        self.unreadCount = unreadCount
        self.pinned = pinned
        self.panes = panes
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case directory
        case focusedPaneID = "focused_pane_id"
        case paneCount = "pane_count"
        case createdAt = "created_at"
        case lastActivityAt = "last_activity_at"
        case sessionID = "session_id"
        case preview
        case unreadCount = "unread_count"
        case pinned
        case panes
    }
}
