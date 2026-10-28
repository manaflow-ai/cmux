/// A terminal key's latency slot as the `flow` of its daemon `send`. The daemon echoes the flow
/// with the key's output and its own stages, so the echo finds the slot with no table on either side.
///
/// Bit 63 tags a slot's flow, so it never equals a typing-probe flow (this process's pid in bits 32-62, the
/// sample below: `TypingLatencyProbe`); the token is bits 0-31.
extension InputLatencyToken {
    private static let keyFlowTag: UInt64 = 1 << 63

    /// The slot's flow: never 0.
    public var keyFlow: UInt64 { Self.keyFlowTag | UInt64(rawValue) }

    /// The slot `keyFlow` names, or nil for a flow that is not a slot's (a typing-probe flow, 0).
    public init?(keyFlow: UInt64) {
        guard keyFlow >> 32 == Self.keyFlowTag >> 32 else { return nil }
        self.init(rawValue: UInt32(truncatingIfNeeded: keyFlow))
    }
}
