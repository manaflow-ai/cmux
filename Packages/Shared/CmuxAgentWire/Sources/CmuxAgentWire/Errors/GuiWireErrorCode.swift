/// A fail-open GUI RPC error code.
public enum GuiWireErrorCode: Codable, Hashable, Sendable {
    /// Request parameters were invalid.
    case invalidParams
    /// Client and server protocol ranges do not overlap.
    case unsupportedProtocol
    /// The requested resource was not found.
    case notFound
    /// The session-to-surface binding was lost.
    case bindingLost
    /// The agent input queue is full.
    case inputQueueFull
    /// The agent process has exited.
    case processExited
    /// The Mac rejected a send request.
    case sendRejected
    /// The caller is rate limited.
    case rateLimited
    /// An internal server error occurred.
    case internalError
    /// An unrecognized future code preserved verbatim.
    case unknown(String)

    /// The open string carried by the RPC envelope.
    public var rawValue: String {
        switch self {
        case .invalidParams: "invalid_params"
        case .unsupportedProtocol: "unsupported_protocol"
        case .notFound: "not_found"
        case .bindingLost: "binding_lost"
        case .inputQueueFull: "input_queue_full"
        case .processExited: "process_exited"
        case .sendRejected: "send_rejected"
        case .rateLimited: "rate_limited"
        case .internalError: "internal_error"
        case .unknown(let rawValue): rawValue
        }
    }

    /// Creates an error code from an open RPC string.
    /// - Parameter rawValue: The raw RPC error code.
    public init(rawValue: String) {
        switch rawValue {
        case "invalid_params": self = .invalidParams
        case "unsupported_protocol": self = .unsupportedProtocol
        case "not_found": self = .notFound
        case "binding_lost": self = .bindingLost
        case "input_queue_full": self = .inputQueueFull
        case "process_exited": self = .processExited
        case "send_rejected": self = .sendRejected
        case "rate_limited": self = .rateLimited
        case "internal_error": self = .internalError
        default: self = .unknown(rawValue)
        }
    }

    /// Decodes an open RPC error code.
    /// - Parameter decoder: The decoder to read from.
    public init(from decoder: any Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    /// Encodes the raw RPC error code.
    /// - Parameter encoder: The encoder to write to.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
