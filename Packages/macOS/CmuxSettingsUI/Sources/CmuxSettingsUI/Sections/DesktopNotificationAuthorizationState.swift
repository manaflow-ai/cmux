import Foundation

/// Host-provided macOS notification authorization state for the Settings UI.
public enum DesktopNotificationAuthorizationState: Equatable, Sendable {
    /// The host has not reported a concrete permission state yet.
    case unknown
    /// macOS has not asked the user for permission yet.
    case notDetermined
    /// macOS allows cmux to deliver desktop notifications.
    case authorized
    /// macOS blocks cmux desktop notifications.
    case denied
    /// macOS allows quiet desktop notification delivery.
    case provisional
    /// macOS granted temporary notification delivery.
    case ephemeral
}
