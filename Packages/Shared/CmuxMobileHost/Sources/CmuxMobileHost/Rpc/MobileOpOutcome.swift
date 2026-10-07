import CmuxMobileWire

/// The decided outcome of one op, replayed for a repeated idempotency key.
public enum MobileOpOutcome: Hashable, Sendable {
    /// The op's value and the stream seq after its effects.
    case result(tx: String, value: JSONValue, sequence: UInt64)
    case reject(tx: String, MobileOpRejection)

    public var ok: Bool {
        if case .result = self { return true }
        return false
    }

    public var sequence: UInt64 {
        if case .result(_, _, let sequence) = self { return sequence }
        return 0
    }
}
