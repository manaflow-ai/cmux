import CmuxTerminalAccess
import Foundation

/// Bearer-token authorisation for the local HTTP control transport
/// (spec §5.2).
///
/// The compare path goes through ``CmuxTerminalAccess/ctCompare(_:_:)``
/// — the same constant-time primitive used by the legacy
/// Unix-socket password check — so the per-byte equality timing
/// signal cannot leak the token even if a future caller diffs
/// HTTP and UDS auth paths (Errata E9). Length mismatch is allowed
/// to leak per the threat model.
public struct HTTPAuth: Sendable {
    /// Outcome of evaluating an `Authorization` header.
    public enum Result: Equatable, Sendable {
        /// Header was absent entirely.
        case missing
        /// Header was present but scheme or token did not match.
        case invalid
        /// Header carried a valid `Bearer` token.
        case ok
    }

    /// Expected token bytes, captured once at construction so
    /// ``evaluate(authorizationHeader:)`` is allocation-free on the
    /// happy path.
    private let expected: Data

    /// Creates a checker bound to `expectedToken`.
    ///
    /// - Parameter expectedToken: Opaque bearer token loaded from the
    ///   token file in `HTTPControlTokenStore`. Treated as raw UTF-8
    ///   bytes; not normalised.
    public init(expectedToken: String) {
        self.expected = Data(expectedToken.utf8)
    }

    /// Validates an `Authorization` header value.
    ///
    /// - Parameter authorizationHeader: Raw header value, or `nil` if
    ///   the header was absent.
    /// - Returns: ``Result/missing`` when the header was absent,
    ///   ``Result/invalid`` for any scheme/token mismatch, or
    ///   ``Result/ok`` when the `Bearer` token matched the expected
    ///   value byte-for-byte.
    public func evaluate(authorizationHeader: String?) -> Result {
        guard let header = authorizationHeader else { return .missing }
        let prefix = "Bearer "
        guard header.hasPrefix(prefix) else { return .invalid }
        let candidate = Data(header.dropFirst(prefix.count).utf8)
        return ctCompare(expected, candidate) ? .ok : .invalid
    }
}
