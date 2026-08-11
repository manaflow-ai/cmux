public import CmuxAgentReplica
import Foundation

/// Summarizes what cmux can safely do with a detected session.
public struct SessionCapabilityReport: Hashable, Sendable {
    /// The session's current detection tier.
    public let tier: DetectionTier
    /// Machine-readable reasons for any capability limits.
    public let reasons: [CapabilityReason]
    /// Whether cmux can steer the session by injecting input.
    public let steerable: Bool
    /// Whether cmux can answer pending questions or permissions.
    public let answerable: Bool

    /// Creates a session capability report.
    /// - Parameters:
    ///   - tier: The detection tier.
    ///   - reasons: Machine-readable limitation reasons.
    ///   - steerable: Whether the session is steerable.
    ///   - answerable: Whether pending asks are answerable.
    public init(tier: DetectionTier, reasons: [CapabilityReason], steerable: Bool, answerable: Bool) {
        self.tier = tier
        self.reasons = reasons
        self.steerable = steerable
        self.answerable = answerable
    }
}
