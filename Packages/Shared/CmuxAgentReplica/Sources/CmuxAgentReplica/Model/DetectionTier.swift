import Foundation

/// Describes how strongly cmux can observe a session.
public enum DetectionTier: String, Codable, Hashable, Sendable {
    /// The session is fully wrapped.
    case wrapped
    /// The session is hooked by integration points.
    case hooked
    /// The session is observed without strong integration.
    case observed
    /// The session is visible through degraded detection.
    case degraded
}
