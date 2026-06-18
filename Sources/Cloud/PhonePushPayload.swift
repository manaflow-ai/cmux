import Foundation

struct PhonePushPayload: Sendable {
    let kind: PhonePushPayloadKind
    let title: String
    let subtitle: String
    let body: String
    let workspaceId: String?
    let surfaceId: String?
    /// Stable notification id (the Mac store ``TerminalNotification/id``).
    /// Travels to APNs as both an `apns-collapse-id` (so a later Mac->iOS
    /// dismiss can target the delivered banner) and `cmux.notificationId`
    /// (so an iOS swipe can tell the Mac which notification was dismissed).
    let notificationId: String?
    /// The dismissed ids a `.dismiss` push carries (else empty).
    let notificationIds: [String]
    /// Authoritative unread total at send time, emitted as `aps.badge`.
    let badgeCount: Int
    let hideContent: Bool
}
