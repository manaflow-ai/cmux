/// Failures reported by ``SubrouterClienting`` implementations.
public enum SubrouterClientError: Error, Sendable, Equatable {
    /// The daemon could not be reached (connection refused, timeout, DNS).
    case unreachable(description: String)
    /// The daemon answered with a non-success HTTP status.
    case httpStatus(code: Int, description: String)
    /// The daemon's payload could not be decoded.
    case decoding(description: String)

    /// A short human-readable description safe to surface in UI and CLI
    /// output (no payload contents beyond a status line).
    public var shortDescription: String {
        switch self {
        case .unreachable(let description):
            return description
        case .httpStatus(let code, let description):
            return description.isEmpty ? "HTTP \(code)" : "HTTP \(code): \(description)"
        case .decoding(let description):
            return description
        }
    }
}
