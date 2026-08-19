public import Foundation

/// Tracks whether an SSH PTY attachment delivered output newer than its
/// initial scrollback replay.
public struct SSHPTYAttachOutputProgress: Sendable {
    /// Initial replay bytes that have not yet arrived from the bridge.
    public private(set) var replayBytesRemaining: Int

    private var replayBytesToSuppressRemaining: Int

    /// Whether any output arrived after the initial replay boundary.
    public private(set) var receivedLiveOutput = false

    /// Creates progress accounting for an attachment's declared replay size.
    ///
    /// - Parameters:
    ///   - replayBytes: Bytes the bridge will send before live output.
    ///   - suppressReplayBytes: Previously delivered replay prefix bytes to
    ///     hide on a managed reattach. `nil` preserves the legacy behavior of
    ///     suppressing the complete declared replay when requested.
    public init(replayBytes: Int, suppressReplayBytes: Int? = nil) {
        let normalizedReplayBytes = max(0, replayBytes)
        replayBytesRemaining = normalizedReplayBytes
        replayBytesToSuppressRemaining = min(
            normalizedReplayBytes,
            max(0, suppressReplayBytes ?? normalizedReplayBytes)
        )
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
    /// every attach. The wrapper already rendered the previously delivered
    /// prefix on its first attempt, so later attempts can discard only that
    /// prefix while forwarding output appended during the detached interval.
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
        let replayChunkBytes = min(data.count, replayBytesRemaining)
        let suppressBytes = suppressingReplay
            ? min(data.count, replayBytesToSuppressRemaining)
            : 0
        recordOutput(byteCount: data.count)
        if suppressingReplay {
            replayBytesToSuppressRemaining -= suppressBytes
            // A partially suppressed replay contains a suffix that was
            // produced after the previous attach. It is live from the pane's
            // perspective even though the daemon labels the whole snapshot
            // as replay.
            if suppressBytes < replayChunkBytes {
                receivedLiveOutput = true
            }
        }
        guard suppressingReplay, suppressBytes > 0 else { return data }
        return Data(data.dropFirst(suppressBytes))
    }
}
