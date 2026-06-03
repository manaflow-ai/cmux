import Foundation

/// A workspace row returned by the mobile inbox sync API.
public struct MobileInboxWorkspaceRow: Codable, Equatable, Sendable, Identifiable {
    /// The row kind discriminator, if provided by the server.
    public let kind: String?

    /// The workspace identifier.
    public let workspaceId: String

    /// The machine identifier hosting the workspace.
    public let machineId: String

    /// The workspace title.
    public let title: String

    /// A short preview of recent activity.
    public let preview: String

    /// The workspace lifecycle phase.
    public let phase: String

    /// The tmux session name backing the workspace.
    public let tmuxSessionName: String

    /// The last-activity time as a Unix timestamp in milliseconds.
    public let lastActivityAt: Double

    /// The latest event sequence number.
    public let latestEventSeq: Int

    /// The last event sequence the user has read.
    public let lastReadEventSeq: Int

    /// Whether the workspace has unread activity.
    public let unread: Bool

    /// The number of unread items.
    public let unreadCount: Int

    /// The display name of the hosting machine.
    public let machineDisplayName: String

    /// The reachability status of the hosting machine.
    public let machineStatus: MobileMachineStatus

    /// The Tailscale hostname of the hosting machine, if any.
    public let tailscaleHostname: String?

    /// The Tailscale IP addresses of the hosting machine.
    public let tailscaleIPs: [String]

    /// The stable identity, equal to ``workspaceId``.
    public var id: String { workspaceId }

    /// Creates an inbox workspace row.
    ///
    /// - Parameters:
    ///   - kind: The row kind discriminator, if provided by the server.
    ///   - workspaceId: The workspace identifier.
    ///   - machineId: The machine identifier hosting the workspace.
    ///   - title: The workspace title.
    ///   - preview: A short preview of recent activity.
    ///   - phase: The workspace lifecycle phase.
    ///   - tmuxSessionName: The tmux session name backing the workspace.
    ///   - lastActivityAt: The last-activity time as a Unix timestamp in milliseconds.
    ///   - latestEventSeq: The latest event sequence number.
    ///   - lastReadEventSeq: The last event sequence the user has read.
    ///   - unread: Whether the workspace has unread activity.
    ///   - unreadCount: The number of unread items.
    ///   - machineDisplayName: The display name of the hosting machine.
    ///   - machineStatus: The reachability status of the hosting machine.
    ///   - tailscaleHostname: The Tailscale hostname of the hosting machine, if any.
    ///   - tailscaleIPs: The Tailscale IP addresses of the hosting machine.
    public init(
        kind: String?,
        workspaceId: String,
        machineId: String,
        title: String,
        preview: String,
        phase: String,
        tmuxSessionName: String,
        lastActivityAt: Double,
        latestEventSeq: Int,
        lastReadEventSeq: Int,
        unread: Bool,
        unreadCount: Int,
        machineDisplayName: String,
        machineStatus: MobileMachineStatus,
        tailscaleHostname: String?,
        tailscaleIPs: [String]
    ) {
        self.kind = kind
        self.workspaceId = workspaceId
        self.machineId = machineId
        self.title = title
        self.preview = preview
        self.phase = phase
        self.tmuxSessionName = tmuxSessionName
        self.lastActivityAt = lastActivityAt
        self.latestEventSeq = latestEventSeq
        self.lastReadEventSeq = lastReadEventSeq
        self.unread = unread
        self.unreadCount = unreadCount
        self.machineDisplayName = machineDisplayName
        self.machineStatus = machineStatus
        self.tailscaleHostname = tailscaleHostname
        self.tailscaleIPs = tailscaleIPs
    }
}
