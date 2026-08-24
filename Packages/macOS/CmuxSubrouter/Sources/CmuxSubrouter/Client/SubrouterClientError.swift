/// Failures reported by ``SubrouterClienting`` implementations.
public enum SubrouterClientError: Error, Sendable, Equatable {
    /// The daemon could not be reached (connection refused, timeout, DNS).
    case unreachable(description: String)
    /// The daemon answered with a non-success HTTP status.
    case httpStatus(code: Int, description: String)
    /// The daemon's payload could not be decoded.
    case decoding(description: String)
    /// The requested operation is not supported by the selected daemon mode.
    case unsupported(description: String)

    /// A short human-readable description safe to surface in UI and CLI
    /// output. Transport and decoding details are intentionally reduced to
    /// stable product messages; callers may retain their associated detail
    /// for internal diagnostics without exposing it to users.
    public var shortDescription: String {
        switch self {
        case .unreachable:
            return String(
                localized: "subrouter.error.unreachable",
                defaultValue: "The subrouter daemon could not be reached."
            )
        case .httpStatus(let code, _):
            return String(
                localized: "subrouter.error.httpStatus",
                defaultValue: "The subrouter daemon returned HTTP \(code)."
            )
        case .decoding:
            return String(
                localized: "subrouter.error.decoding",
                defaultValue: "The subrouter daemon returned an invalid response."
            )
        case .unsupported(let description):
            return description
        }
    }
}
