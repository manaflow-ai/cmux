public import Foundation

/// One notification mirrored from the active Mac's notification store.
public struct MobileNotificationFeedItem: Identifiable, Equatable, Sendable {
    /// The stable notification identifier.
    public let id: UUID
    /// The Mac-local workspace identifier that produced the notification.
    public let workspaceID: UUID
    /// The exact terminal surface identifier, when the notification names one.
    public let surfaceID: UUID?
    /// The notification title.
    public let title: String
    /// The optional secondary title text.
    public let subtitle: String
    /// The notification body.
    public let body: String
    /// The creation instant reported by the Mac.
    public let createdAt: Date
    /// Whether the notification has already been read.
    public let isRead: Bool
    /// The current workspace display name, or `nil` when that workspace is gone.
    public let workspaceName: String?

    /// Creates a notification feed item.
    public init(
        id: UUID,
        workspaceID: UUID,
        surfaceID: UUID? = nil,
        title: String,
        subtitle: String = "",
        body: String = "",
        createdAt: Date,
        isRead: Bool,
        workspaceName: String? = nil
    ) {
        self.id = id
        self.workspaceID = workspaceID
        self.surfaceID = surfaceID
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.createdAt = createdAt
        self.isRead = isRead
        self.workspaceName = workspaceName
    }

    /// Returns a copy with an updated read state.
    /// - Parameter isRead: The read state for the returned value.
    /// - Returns: A copy of this item with `isRead` replaced.
    public func settingRead(_ isRead: Bool) -> Self {
        Self(
            id: id,
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            title: title,
            subtitle: subtitle,
            body: body,
            createdAt: createdAt,
            isRead: isRead,
            workspaceName: workspaceName
        )
    }

    init?(payload: [String: Any]) {
        guard
            let rawID = payload["id"] as? String,
            let id = UUID(uuidString: rawID),
            let rawWorkspaceID = payload["workspace_id"] as? String,
            let workspaceID = UUID(uuidString: rawWorkspaceID),
            let createdAt = Self.epochSeconds(from: payload["created_at"]),
            let isRead = payload["is_read"] as? Bool
        else {
            return nil
        }
        if let rawSurfaceID = payload["surface_id"] as? String,
           !rawSurfaceID.isEmpty,
           UUID(uuidString: rawSurfaceID) == nil {
            return nil
        }
        self.init(
            id: id,
            workspaceID: workspaceID,
            surfaceID: (payload["surface_id"] as? String).flatMap(UUID.init(uuidString:)),
            title: payload["title"] as? String ?? "",
            subtitle: payload["subtitle"] as? String ?? "",
            body: payload["body"] as? String ?? "",
            createdAt: Date(timeIntervalSince1970: createdAt),
            isRead: isRead,
            workspaceName: Self.nonemptyString(payload["workspace_name"])
        )
    }

    private static func epochSeconds(from value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        if let value = value as? NSNumber { return value.doubleValue }
        return nil
    }

    private static func nonemptyString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
