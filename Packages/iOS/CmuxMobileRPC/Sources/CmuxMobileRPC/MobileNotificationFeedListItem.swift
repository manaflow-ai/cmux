public import Foundation

/// One notification returned by the Mac's `notification.feed.list` RPC.
public struct MobileNotificationFeedListItem: Decodable, Equatable, Sendable {
    /// The Mac-local notification identifier.
    public let id: String
    /// The Mac-local workspace identifier that owns the notification.
    public let workspaceID: String
    /// The Mac-local pane or terminal-surface identifier, when the notification targets one.
    public let surfaceID: String?
    /// The notification's primary title.
    public let title: String
    /// The notification's optional secondary title.
    public let subtitle: String?
    /// The notification body.
    public let body: String
    /// The notification creation date.
    public let createdAt: Date
    /// Whether the notification has been read on the Mac.
    public let isRead: Bool
    /// Whether a terminal that moved may open in its current workspace.
    public let retargetsToLiveSurfaceOwner: Bool
    /// The current destination workspace label resolved by the Mac, when available.
    public let workspaceTitle: String?
    /// The current destination pane label resolved by the Mac, when available.
    public let surfaceTitle: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case workspaceID = "workspace_id"
        case surfaceID = "surface_id"
        case title
        case subtitle
        case body
        case createdAt = "created_at"
        case isRead = "is_read"
        case retargetsToLiveSurfaceOwner = "retargets_to_live_surface_owner"
        case workspaceTitle = "workspace_title"
        case surfaceTitle = "surface_title"
    }

    /// Decodes one feed item from its wire representation.
    /// - Parameter decoder: The JSON decoder for the item payload.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        workspaceID = try container.decode(String.self, forKey: .workspaceID)
        surfaceID = try container.decodeIfPresent(String.self, forKey: .surfaceID)
        title = try container.decode(String.self, forKey: .title)
        subtitle = try container.decodeIfPresent(String.self, forKey: .subtitle)
        body = try container.decode(String.self, forKey: .body)
        createdAt = Date(timeIntervalSince1970: try container.decode(Double.self, forKey: .createdAt))
        isRead = try container.decode(Bool.self, forKey: .isRead)
        // Notification feed capability predates this provenance field only in
        // development builds. Missing provenance stays confined by default.
        retargetsToLiveSurfaceOwner = try container.decodeIfPresent(
            Bool.self,
            forKey: .retargetsToLiveSurfaceOwner
        ) ?? false
        workspaceTitle = try container.decodeIfPresent(String.self, forKey: .workspaceTitle)
        surfaceTitle = try container.decodeIfPresent(String.self, forKey: .surfaceTitle)
    }
}
