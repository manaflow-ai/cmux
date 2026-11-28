import Foundation

/// `TabNotification` is generated from the schema's `NotificationMarker` (swift_app/bindings.json, Tree family).
public enum NotificationLevel: String, Sendable, Hashable, Codable {
    case info, warning, error
}
