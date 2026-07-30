import Foundation

/// The desktop presentation surface used for terminal notifications.
public enum NotificationDeliveryMode: String, Codable, CaseIterable, Sendable, SettingCodable {
    /// Deliver through macOS Notification Center.
    case system

    /// Present an interactive DynamicNotchKit panel inside cmux.
    case dynamicNotch
}
