public import Foundation

/// Typed decoder for a `notification.dismissed` push-event payload.
///
/// Emitted by the Mac when one or more delivered notifications are dismissed or
/// cleared on the Mac (a banner swipe, "Mark read", or "Clear All"), so an
/// attached phone can clear the matching mirrored banners. The payload carries
/// only the stable notification ids (`{"ids": ["<uuid>", …]}`) and never any
/// terminal content, so dismiss-sync is safe even when phone-forward
/// hideContent is enabled.
public struct MobileNotificationDismissedEvent: Decodable, Sendable {
    /// The stable notification ids the Mac dismissed. These match the
    /// `apns-collapse-id` of the corresponding delivered remote notifications, so
    /// the phone can target them with
    /// `removeDeliveredNotifications(withIdentifiers:)`.
    public let ids: [String]

    private enum CodingKeys: String, CodingKey {
        case ids
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawIDs = try container.decodeIfPresent([String].self, forKey: .ids) ?? []
        ids = rawIDs
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Decode a `notification.dismissed` event from a raw JSON payload.
    /// - Parameter data: The event payload JSON.
    /// - Returns: The decoded event, or `nil` when the payload is malformed.
    public static func decode(_ data: Data) -> MobileNotificationDismissedEvent? {
        try? JSONDecoder().decode(Self.self, from: data)
    }
}
