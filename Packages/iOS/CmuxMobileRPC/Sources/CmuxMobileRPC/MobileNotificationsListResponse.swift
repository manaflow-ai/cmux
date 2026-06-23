public import Foundation

/// Typed decoder for the `mobile.notifications.list` RPC result.
///
/// The wire shape is snake_case (the Mac emits it that way, matching
/// `workspace.list`); `CodingKeys` map it onto camelCase Swift properties
/// without changing the wire. The list is newest-first as produced by the Mac.
public struct MobileNotificationsListResponse: Decodable, Sendable {
    /// The recent notifications, newest-first as produced by the Mac.
    public let notifications: [MobileNotificationListRow]

    private enum CodingKeys: String, CodingKey {
        case notifications
    }

    /// Decode a notifications-list response from raw JSON data.
    /// - Parameter data: The RPC result payload.
    /// - Returns: The decoded response.
    /// - Throws: A decoding error if the payload is malformed.
    public static func decode(_ data: Data) throws -> MobileNotificationsListResponse {
        try JSONDecoder().decode(Self.self, from: data)
    }

    /// Map the decoded wire rows into iOS-facing value previews.
    public func previews() -> [MobileNotificationPreview] {
        notifications.map { row in
            MobileNotificationPreview(
                id: row.id,
                workspaceID: row.workspaceID,
                surfaceID: row.surfaceID,
                title: row.title,
                subtitle: row.subtitle,
                body: row.body,
                isContentHidden: row.isContentHidden,
                createdAt: Date(timeIntervalSince1970: row.createdAt),
                isRead: row.isRead
            )
        }
    }
}
