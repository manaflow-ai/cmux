public import Foundation

/// When the Mac should forward terminal notifications to this phone once
/// phone notifications are enabled.
public enum MobileNotificationForwardingMode: String, CaseIterable, Hashable, Identifiable, Sendable {
    /// Forward every notification regardless of whether the Mac was recently used.
    case always
    /// Forward only when the Mac is locked, asleep, screensaving, or idle.
    case onlyWhenAway

    /// The phone-active default: enabling phone notifications should not require
    /// the user to discover the Mac's separate Always mode.
    public static let defaultMode: MobileNotificationForwardingMode = .always

    /// Stable picker identity matching the raw value.
    public var id: String { rawValue }
}
