/// Where a transfer stands. `paused` and retryable `failed` resume.
public enum TransferStatus: Hashable, Sendable, Codable {
    case running
    case paused
    case finished
    case failed(code: String, message: String, retryable: Bool)
    case cancelled

    public var isTerminal: Bool {
        switch self {
        case .running, .paused: false
        case .finished, .cancelled: true
        case .failed(_, _, let retryable): !retryable
        }
    }
}
