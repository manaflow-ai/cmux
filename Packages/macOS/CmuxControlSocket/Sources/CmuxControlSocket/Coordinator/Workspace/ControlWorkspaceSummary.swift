public import Foundation

/// A read-only snapshot of one workspace, as the app target exposes it to
/// ``ControlCommandCoordinator`` through ``ControlWorkspaceContext``.
///
/// Mirrors the fields the legacy `v2WorkspaceSummaryPayload` read off a live
/// `Workspace`, with the app-typed `remoteStatusPayload()` already bridged to a
/// ``JSONValue`` so no app types cross the seam. The coordinator turns each
/// summary into the `workspace.list` / `workspace.current` payload row,
/// minting the workspace ref and writing the `selected` / `index` keys it owns.
public struct ControlWorkspaceSummary: Sendable, Equatable {
    /// The workspace's stable identifier.
    public let id: UUID
    /// The workspace's display title.
    public let title: String
    /// The user-set title, if any.
    public let customTitle: String?
    /// The user-set description, if any (the legacy `v2OrNull` field).
    public let customDescription: String?
    /// Whether the workspace is pinned.
    public let isPinned: Bool
    /// The workspace's currently-listening ports, in app order.
    public let listeningPorts: [Int]
    /// The bridged `remoteStatusPayload()` object.
    public let remoteStatus: JSONValue
    /// The workspace's current working directory, if any.
    public let currentDirectory: String?
    /// The workspace's stable default working directory, if any.
    public let defaultWorkingDirectory: String?
    /// The user-set custom color, if any.
    public let customColor: String?
    /// The latest conversation message, if any.
    public let latestConversationMessage: String?
    /// The latest submitted message, if any.
    public let latestSubmittedMessage: String?
    /// The latest submitted timestamp (already ISO-formatted), if any.
    public let latestSubmittedAt: String?

    /// Creates a workspace summary.
    ///
    /// - Parameters:
    ///   - id: The workspace's stable identifier.
    ///   - title: The display title.
    ///   - customTitle: The user-set title, if any.
    ///   - customDescription: The user-set description, if any.
    ///   - isPinned: Whether the workspace is pinned.
    ///   - listeningPorts: The listening ports.
    ///   - remoteStatus: The bridged `remoteStatusPayload()` object.
    ///   - currentDirectory: The current working directory, if any.
    ///   - defaultWorkingDirectory: The stable default working directory, if any.
    ///   - customColor: The custom color, if any.
    ///   - latestConversationMessage: The latest conversation message, if any.
    ///   - latestSubmittedMessage: The latest submitted message, if any.
    ///   - latestSubmittedAt: The ISO-formatted latest submitted timestamp, if any.
    public init(
        id: UUID,
        title: String,
        customTitle: String?,
        customDescription: String?,
        isPinned: Bool,
        listeningPorts: [Int],
        remoteStatus: JSONValue,
        currentDirectory: String?,
        defaultWorkingDirectory: String?,
        customColor: String?,
        latestConversationMessage: String?,
        latestSubmittedMessage: String?,
        latestSubmittedAt: String?
    ) {
        self.id = id
        self.title = title
        self.customTitle = customTitle
        self.customDescription = customDescription
        self.isPinned = isPinned
        self.listeningPorts = listeningPorts
        self.remoteStatus = remoteStatus
        self.currentDirectory = currentDirectory
        self.defaultWorkingDirectory = defaultWorkingDirectory
        self.customColor = customColor
        self.latestConversationMessage = latestConversationMessage
        self.latestSubmittedMessage = latestSubmittedMessage
        self.latestSubmittedAt = latestSubmittedAt
    }
}
