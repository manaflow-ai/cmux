/// Tracks whether an SSH PTY attachment delivered output newer than its
/// initial scrollback replay.
public struct SSHPTYAttachOutputProgress: Sendable {
    /// Initial replay bytes that have not yet arrived from the bridge.
    public private(set) var replayBytesRemaining: Int

    /// Whether any output arrived after the initial replay boundary.
    public private(set) var receivedLiveOutput = false

    /// Creates progress accounting for an attachment's declared replay size.
    public init(replayBytes: Int) {
        replayBytesRemaining = max(0, replayBytes)
    }

    /// Records one ordered output chunk from the bridge.
    public mutating func recordOutput(byteCount: Int) {
        guard byteCount > 0 else { return }
        let replayBytes = min(byteCount, replayBytesRemaining)
        replayBytesRemaining -= replayBytes
        if byteCount > replayBytes {
            receivedLiveOutput = true
        }
    }
}
