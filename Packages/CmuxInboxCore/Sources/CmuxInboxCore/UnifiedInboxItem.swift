public import CmuxMobileContract
public import Foundation

/// A single row displayed in the unified inbox, representing either an agent conversation or a terminal workspace.
public struct UnifiedInboxItem: Identifiable, Equatable, Codable, Sendable {
    /// The stable identity, derived from ``kind`` plus the conversation or workspace identifier.
    public let id: String
    /// Whether this item is a conversation or a workspace.
    public let kind: UnifiedInboxKind
    /// The conversation identifier, when ``kind`` is ``UnifiedInboxKind/conversation``.
    public let conversationID: String?
    /// The workspace identifier, when ``kind`` is ``UnifiedInboxKind/workspace``.
    public let workspaceID: String?
    /// The machine identifier hosting the item, if known.
    public let machineID: String?
    /// The team identifier owning the item, if known.
    public let teamID: String?
    /// The display title.
    public let title: String
    /// A short preview of recent activity.
    public let preview: String
    /// The number of unread items.
    public let unreadCount: Int
    /// The timestamp used to sort the inbox.
    public let sortDate: Date
    /// An optional secondary label (for example the hosting machine's display name).
    public let accessoryLabel: String?
    /// An optional SF Symbol name for the item's icon.
    public let symbolName: String?
    /// The tmux session name backing the workspace, if any.
    public let tmuxSessionName: String?
    /// The latest event sequence number known for the item, if any.
    public let latestEventSeq: Int?
    /// The last event sequence number the user has read, if any.
    public let lastReadEventSeq: Int?
    /// The Tailscale hostname of the hosting machine, if any.
    public let tailscaleHostname: String?
    /// The Tailscale IP addresses of the hosting machine.
    public let tailscaleIPs: [String]
    /// The reachability status of the hosting machine, if known.
    public let machineStatus: MobileMachineStatus?

    /// Creates a unified inbox item.
    ///
    /// The ``id`` is derived from `kind` plus the matching conversation or workspace identifier; when the
    /// identifier is `nil` a random UUID is substituted so the item still has a stable identity for the session.
    ///
    /// - Parameters:
    ///   - kind: Whether this item is a conversation or a workspace.
    ///   - conversationID: The conversation identifier, when `kind` is `.conversation`.
    ///   - workspaceID: The workspace identifier, when `kind` is `.workspace`.
    ///   - machineID: The machine identifier hosting the item, if known.
    ///   - teamID: The team identifier owning the item, if known.
    ///   - title: The display title.
    ///   - preview: A short preview of recent activity.
    ///   - unreadCount: The number of unread items.
    ///   - sortDate: The timestamp used to sort the inbox.
    ///   - accessoryLabel: An optional secondary label.
    ///   - symbolName: An optional SF Symbol name for the item's icon.
    ///   - tmuxSessionName: The tmux session name backing the workspace, if any.
    ///   - latestEventSeq: The latest event sequence number known for the item, if any.
    ///   - lastReadEventSeq: The last event sequence number the user has read, if any.
    ///   - tailscaleHostname: The Tailscale hostname of the hosting machine, if any.
    ///   - tailscaleIPs: The Tailscale IP addresses of the hosting machine.
    ///   - machineStatus: The reachability status of the hosting machine, if known.
    public init(
        kind: UnifiedInboxKind,
        conversationID: String? = nil,
        workspaceID: String? = nil,
        machineID: String? = nil,
        teamID: String? = nil,
        title: String,
        preview: String,
        unreadCount: Int,
        sortDate: Date,
        accessoryLabel: String? = nil,
        symbolName: String? = nil,
        tmuxSessionName: String? = nil,
        latestEventSeq: Int? = nil,
        lastReadEventSeq: Int? = nil,
        tailscaleHostname: String? = nil,
        tailscaleIPs: [String] = [],
        machineStatus: MobileMachineStatus? = nil
    ) {
        self.kind = kind
        self.conversationID = conversationID
        self.workspaceID = workspaceID
        self.machineID = machineID
        self.teamID = teamID
        self.title = title
        self.preview = preview
        self.unreadCount = unreadCount
        self.sortDate = sortDate
        self.accessoryLabel = accessoryLabel
        self.symbolName = symbolName
        self.tmuxSessionName = tmuxSessionName
        self.latestEventSeq = latestEventSeq
        self.lastReadEventSeq = lastReadEventSeq
        self.tailscaleHostname = tailscaleHostname
        self.tailscaleIPs = tailscaleIPs
        self.machineStatus = machineStatus

        switch kind {
        case .conversation:
            self.id = "conversation:\(conversationID ?? UUID().uuidString)"
        case .workspace:
            self.id = "workspace:\(workspaceID ?? UUID().uuidString)"
        }
    }

    /// Whether the item has any unread activity.
    public var isUnread: Bool {
        unreadCount > 0
    }

    /// Returns whether the item matches a search query.
    ///
    /// The match is case- and diacritic-insensitive against the title, preview, and accessory label. An
    /// empty or whitespace-only query matches every item.
    ///
    /// - Parameter query: The search text to match against.
    /// - Returns: `true` when the query is empty or any searchable field contains it.
    public func matches(query: String) -> Bool {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).localizedLowercase
        guard !normalized.isEmpty else { return true }
        return title.localizedLowercase.contains(normalized) ||
            preview.localizedLowercase.contains(normalized) ||
            (accessoryLabel?.localizedLowercase.contains(normalized) ?? false)
    }
}

extension UnifiedInboxItem {
    /// Creates a workspace inbox item from a mobile inbox sync row.
    ///
    /// - Parameters:
    ///   - workspaceRow: The workspace row returned by the mobile inbox sync API.
    ///   - teamID: The team identifier owning the workspace.
    public init(workspaceRow: MobileInboxWorkspaceRow, teamID: String) {
        self.init(
            kind: .workspace,
            workspaceID: workspaceRow.workspaceId,
            machineID: workspaceRow.machineId,
            teamID: teamID,
            title: workspaceRow.title,
            preview: workspaceRow.preview.isEmpty ? "No recent activity" : workspaceRow.preview,
            unreadCount: workspaceRow.unreadCount,
            sortDate: workspaceRow.lastActivityAt > 0
                ? Date(timeIntervalSince1970: workspaceRow.lastActivityAt / 1000)
                : Date(),
            accessoryLabel: workspaceRow.machineDisplayName,
            symbolName: "terminal",
            tmuxSessionName: workspaceRow.tmuxSessionName,
            latestEventSeq: workspaceRow.latestEventSeq,
            lastReadEventSeq: workspaceRow.lastReadEventSeq,
            tailscaleHostname: workspaceRow.tailscaleHostname,
            tailscaleIPs: workspaceRow.tailscaleIPs,
            machineStatus: workspaceRow.machineStatus
        )
    }
}
