import Foundation

/// Reason a capture candidate was rejected safely.
public enum ArtifactSkipReason: String, Equatable, Sendable {
    /// Automatic capture is disabled by project configuration.
    case automaticCaptureDisabled
    /// The candidate's provenance and location do not meet automatic policy.
    case provenanceNotEligible
    /// The path does not resolve to a regular file.
    case notARegularFile
    /// The filename extension is not allowlisted.
    case unsupportedExtension
    /// The file exceeds the configured size limit.
    case exceedsSizeLimit
    /// This scan already reached its configured candidate limit.
    case candidateLimitReached
}
