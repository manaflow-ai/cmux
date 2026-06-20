import Foundation

enum PhonePushPayloadKind: String, Sendable {
    /// Visible banner mirror of a Mac notification.
    case notify
    /// Silent banner-removal + badge push (Mac-side dismiss, cold lane).
    case dismiss
}
