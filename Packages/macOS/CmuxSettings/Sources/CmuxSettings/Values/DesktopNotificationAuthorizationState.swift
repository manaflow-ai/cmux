import Foundation

/// OS-level desktop notification authorization state reported to Settings.
public enum DesktopNotificationAuthorizationState: String, CaseIterable, Sendable, Equatable {
    /// The host has not read the OS authorization state yet.
    case unknown
    /// macOS has not asked the user for notification permission yet.
    case notDetermined
    /// macOS allows cmux to deliver desktop notifications.
    case authorized
    /// macOS denies cmux desktop notifications until the user changes System Settings.
    case denied
    /// macOS allows quiet notification delivery.
    case provisional
    /// macOS allows notification delivery temporarily.
    case ephemeral

    /// Whether this state permits desktop notification delivery.
    public var allowsDesktopDelivery: Bool {
        switch self {
        case .authorized, .provisional, .ephemeral:
            true
        case .unknown, .notDetermined, .denied:
            false
        }
    }
}
