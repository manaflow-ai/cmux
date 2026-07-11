import CmuxAgentReplica
import Foundation

/// Builds phone-facing capability reports from reducer evidence.
public struct CapabilityReportBuilder: Sendable {
    /// Creates a capability report builder.
    public init() {}

    /// Builds a capability report for one session's evidence.
    /// - Parameter evidence: The session evidence.
    /// - Returns: A report describing tier, limitations, and allowed actions.
    public func report(for evidence: DetectionEvidence) -> SessionCapabilityReport {
        let tier = evidence.tier
        var reasons = Array(evidence.reasons).sorted { lhs, rhs in
            lhs.localizationKey < rhs.localizationKey
        }
        if !evidence.hasHookEvents {
            reasons.append(.hooksNotObserved)
        }
        let steerable = tier == .wrapped || tier == .hooked
        let answerable = evidence.hasHookEvents && tier != .degraded
        return SessionCapabilityReport(tier: tier, reasons: reasons, steerable: steerable, answerable: answerable)
    }
}
