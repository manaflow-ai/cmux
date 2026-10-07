/// Receiver counters for the pane's status line.
public nonisolated struct RemoteRdStats: Sendable, Hashable {
    /// Newest frame released to the decoder (the feedback acknowledgement).
    public var ackedFrame: UInt32
    /// Whether the next feedback asks the host to recover.
    public var needRecovery: Bool
    /// Frames released to the decoder.
    public var framesReleased: UInt64
    /// Frames that missed their deadline, lost their reference, or were
    /// dropped because the caller fell behind.
    public var framesLost: UInt64
}
