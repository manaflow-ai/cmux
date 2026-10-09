import CmuxMobileWire

/// The outcome of one idempotent op sent over the mobile link's RPC channel.
public enum MobileLinkOperationResult: Hashable, Sendable {
    case applied(value: JSONValue, revision: UInt64, replayed: Bool)
    case rejected(code: String, message: String, retryable: Bool, replayed: Bool)
}
