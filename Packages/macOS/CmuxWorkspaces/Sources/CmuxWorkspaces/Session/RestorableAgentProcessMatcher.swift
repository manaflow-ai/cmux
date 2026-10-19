/// Classifies process evidence used by automatic agent-session restore.
public struct RestorableAgentProcessMatcher: Sendable {
    /// Creates a stateless process matcher.
    public init() {}

    /// Returns whether the evidence authenticates the recorded process generation.
    ///
    /// A legacy record without a saved generation never authenticates a matching
    /// process, but contradictory argv or scope evidence still proves that a reused
    /// PID cannot block restoration. Confirmed absence overrides any identity
    /// captured before the process exited.
    ///
    /// - Parameter evidence: Process observations for the saved PID.
    /// - Returns: A match only for an authenticated generation, a mismatch for
    ///   definitive contradictory evidence, or unknown when observations are inconclusive.
    public func match(_ evidence: RestorableAgentProcessEvidence) -> RestorableAgentProcessMatch {
        guard evidence.presence != .absent else { return .mismatches }

        if let recordedIdentity = evidence.recordedIdentity {
            guard Int(recordedIdentity.pid) == evidence.processID else {
                return .unknown
            }
            guard let currentIdentity = evidence.currentIdentity,
                  Int(currentIdentity.pid) == evidence.processID else {
                return .unknown
            }
            guard currentIdentity == recordedIdentity else {
                return .mismatches
            }
        }

        if evidence.scopeMatches == false || evidence.expectedProcessMatches == false {
            return .mismatches
        }
        guard evidence.scopeMatches != nil, evidence.expectedProcessMatches != nil else {
            return .unknown
        }
        return evidence.recordedIdentity == nil ? .unknown : .matches
    }
}
