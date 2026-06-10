public import Foundation

/// Typed decoder for the `notification.reconcile` RPC result.
///
/// The phone's foreground/connect reconcile sweep sends the Mac the identifiers
/// of its currently delivered banners; the Mac answers with the subset that was
/// handled there (read in the store, or recently dismissed/removed) plus its
/// authoritative unread count. The phone removes the handled banners and SETS
/// its app-icon badge to the count, healing anything the live event or silent
/// push lanes missed while the app was closed. Carries only opaque ids and a
/// count, never terminal content.
public struct MobileNotificationReconcileResponse: Decodable, Sendable {
    /// The delivered-banner ids the Mac reports as handled.
    public let handledIDs: [String]
    /// The Mac's authoritative unread-notification count, when sent.
    public let unreadCount: Int?

    private enum CodingKeys: String, CodingKey {
        case handledIDs = "handled_ids"
        case unreadCount = "unread_count"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawIDs = try container.decodeIfPresent([String].self, forKey: .handledIDs) ?? []
        handledIDs = rawIDs
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        unreadCount = try container.decodeIfPresent(Int.self, forKey: .unreadCount)
    }

    /// Decode a reconcile response from the raw RPC result payload.
    /// - Parameter data: The RPC result JSON.
    /// - Returns: The decoded response.
    /// - Throws: A decoding error if the payload is not a JSON object.
    public static func decode(_ data: Data) throws -> MobileNotificationReconcileResponse {
        try JSONDecoder().decode(Self.self, from: data)
    }
}
