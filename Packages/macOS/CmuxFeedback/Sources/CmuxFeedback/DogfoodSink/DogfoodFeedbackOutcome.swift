import Foundation

/// The result of attempting to persist a dogfood feedback submission. Every
/// case maps one-to-one onto the RPC response the host returns to the phone, so
/// the host router can translate without re-deriving any error text or codes.
public enum DogfoodFeedbackOutcome: Sendable, Equatable {
    /// The caller's account is not in the privileged feedback domain. Maps to an
    /// `unauthorized` RPC error.
    case unauthorized

    /// A field exceeded its size cap (or the decoded blob exceeded the byte
    /// cap). Maps to an `invalid_params` RPC error carrying `reason`.
    case invalidParams(reason: String)

    /// The bundle directory or files could not be created on disk. Maps to an
    /// `internal_error` RPC error.
    case internalError

    /// The bundle was written. Carries the absolute bundle directory path and
    /// the number of bytes written to `diagnostic.log`.
    case written(bundlePath: String, diagnosticLogBytes: Int)
}
