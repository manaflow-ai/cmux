import Foundation

/// Reason a capture candidate was rejected safely.
public enum ArtifactSkipReason: String, Equatable, Sendable {
    /// Automatic capture is disabled by project configuration.
    case automaticCaptureDisabled
    /// The candidate's provenance and location do not meet automatic policy.
    case provenanceNotEligible
    /// The path does not resolve to a regular file.
    case notARegularFile
    /// The requested path does not remain confined to the local artifact store.
    case pathOutsideStore
    /// Existing provenance metadata is corrupt and must not be overwritten.
    case corruptProvenance
    /// Git does not prove the artifact store is ignored and untracked.
    case gitPrivacyUnavailable
    /// Another process currently owns the artifact store mutation lease.
    case storeBusy
    /// The filename extension is not allowlisted.
    case unsupportedExtension
    /// The file exceeds the configured size limit.
    case exceedsSizeLimit
    /// This scan already reached its configured candidate limit.
    case candidateLimitReached
}
