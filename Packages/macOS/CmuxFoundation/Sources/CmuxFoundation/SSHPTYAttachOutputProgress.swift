import Foundation

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

    /// Returns the portion of one bridge chunk that belongs in the terminal.
    ///
    /// A managed reconnect may receive the same initial scrollback snapshot on
    /// every attach. The wrapper already rendered that snapshot on its first
    /// attempt, so later attempts account for those bytes for liveness but can
    /// discard them before forwarding the chunk to the pane.
    ///
    /// - Parameters:
    ///   - data: Ordered bytes read from the bridge.
    ///   - suppressingReplay: Whether the current managed attempt should hide
    ///     its declared initial replay.
    /// - Returns: Bytes that should be forwarded to the terminal.
    public mutating func terminalOutput(
        from data: Data,
        suppressingReplay: Bool
    ) -> Data {
        guard !data.isEmpty else { return Data() }
        let replayBytes = min(data.count, replayBytesRemaining)
        recordOutput(byteCount: data.count)
        guard suppressingReplay, replayBytes > 0 else { return data }
        return Data(data.dropFirst(replayBytes))
    }
}
