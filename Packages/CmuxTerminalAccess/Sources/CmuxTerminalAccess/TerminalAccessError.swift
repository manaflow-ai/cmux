/// Typed domain error for every ``TerminalAccessService`` operation.
///
/// Transports (the HTTP layer in Phase 1) map these onto their own
/// status model via ``httpStatus`` and ``wireCode``.
///
/// Two cases need explicit callouts because they resolve coverage
/// must-fixes in the design plan:
/// - ``unsupported(reason:)`` always maps to **HTTP 415** (D18 —
///   picked over 400 to keep "wrong content type" distinct from
///   "wrong payload shape").
/// - ``featureDisabled`` always maps to **HTTP 404** with wire code
///   `not_found` (D11 — never reveal that a toggle exists; an
///   off-by-policy endpoint must be indistinguishable from a
///   genuinely missing route).
public enum TerminalAccessError: Error, Sendable, Equatable {
    /// Surface handle does not resolve to a live surface.
    case unknownSurface
    /// Bearer token is missing or invalid.
    case unauthorized
    /// Caller is authenticated but not permitted; `reason` is shown to
    /// the user.
    case forbidden(reason: String)
    /// Request payload is malformed or fails validation; `reason` is
    /// surfaced verbatim.
    case badRequest(reason: String)
    /// Input exceeds the per-surface queue cap (D7).
    case payloadTooLarge
    /// Token-bucket exhausted on the relevant key (D10).
    case rateLimited
    /// Endpoint is gated off by Settings (D11 — exposed as 404).
    case featureDisabled
    /// Request media type or feature isn't supported; `reason` carries
    /// a human-readable description (D18 — exposed as 415).
    case unsupported(reason: String)
    /// Underlying ghostty/PTY error bubbled up to the transport.
    case ghosttyError(String)

    /// HTTP status per spec §12 and locked decisions D11/D18.
    public var httpStatus: Int {
        switch self {
        case .badRequest:
            return 400
        case .unauthorized:
            return 401
        case .forbidden:
            return 403
        case .unknownSurface, .featureDisabled:
            return 404 // D11
        case .payloadTooLarge:
            return 413
        case .unsupported:
            return 415 // D18
        case .rateLimited:
            return 429
        case .ghosttyError:
            return 500
        }
    }

    /// Stable wire code used in `{ "error": { "code": ... } }`.
    public var wireCode: String {
        switch self {
        case .unknownSurface:
            return "unknown_surface"
        case .unauthorized:
            return "unauthorized"
        case .forbidden:
            return "forbidden"
        case .badRequest:
            return "bad_request"
        case .payloadTooLarge:
            return "payload_too_large"
        case .rateLimited:
            return "rate_limited"
        case .featureDisabled:
            return "not_found" // D11 — don't reveal toggle
        case .unsupported:
            return "unsupported_media_type"
        case .ghosttyError:
            return "internal_error"
        }
    }

    /// Human-readable message for the JSON error body.
    public var message: String {
        switch self {
        case .unknownSurface:
            return "Unknown surface"
        case .unauthorized:
            return "Missing or invalid token"
        case .forbidden(let r):
            return r
        case .badRequest(let r):
            return r
        case .payloadTooLarge:
            return "Input exceeds queue cap"
        case .rateLimited:
            return "Rate limit exceeded"
        case .featureDisabled:
            return "Endpoint not available"
        case .unsupported(let r):
            return r
        case .ghosttyError(let r):
            return r
        }
    }
}
