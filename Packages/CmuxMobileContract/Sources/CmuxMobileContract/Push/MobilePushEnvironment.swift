import Foundation

/// The APNs delivery environment a push token is registered for.
public enum MobilePushEnvironment: String, Codable, Equatable, Sendable {
    /// The APNs sandbox environment used by development builds.
    case development

    /// The APNs production environment used by release builds.
    case production
}
