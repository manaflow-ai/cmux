public import Foundation

/// Turns an SSH PTY attachment's bridge output into terminal output.
///
/// Pairs the replay progress accounting, which decides when input forwarding
/// may start, with the replay query filter, which keeps historical terminal
/// queries away from the local emulator. Both see the same ordered stream.
public struct SSHPTYAttachReplayOutputStream: Sendable {
    /// Replay accounting for the attachment.
    public private(set) var progress: SSHPTYAttachOutputProgress
    private var queryFilter: SSHPTYReplayOutputFilter

    /// Creates the output stream for one attachment.
    ///
    /// - Parameters:
    ///   - progress: Replay accounting for the attachment's declared replay.
    ///   - queryFilterReplayBytes: Leading bytes whose terminal queries are
    ///     removed; zero forwards every query.
    public init(progress: SSHPTYAttachOutputProgress, queryFilterReplayBytes: Int) {
        self.progress = progress
        queryFilter = SSHPTYReplayOutputFilter(replayBytes: queryFilterReplayBytes)
    }

    /// Returns the bytes of one bridge chunk that belong in the terminal.
    ///
    /// - Parameters:
    ///   - data: Ordered bytes read from the bridge.
    ///   - suppressingReplay: Whether this managed attempt hides the replay
    ///     prefix an earlier attempt already rendered.
    public mutating func terminalOutput(from data: Data, suppressingReplay: Bool) -> Data {
        queryFilter.filter(progress.terminalOutput(from: data, suppressingReplay: suppressingReplay))
    }

    /// Ends the replay phase after the caller's replay deadline expired.
    ///
    /// - Returns: Buffered replay output that must still reach the terminal.
    public mutating func endStalledReplay() -> Data {
        let output = queryFilter.filter(progress.endReplay())
        queryFilter.endReplay()
        return output
    }

    /// Flushes everything still held when the bridge closes.
    ///
    /// - Parameter discardingPendingReplay: Drop an unvalidated replay
    ///   candidate because another managed attempt will render it.
    public mutating func finish(discardingPendingReplay: Bool) -> Data {
        var output = queryFilter.filter(
            progress.finishPendingReplay(discarding: discardingPendingReplay)
        )
        output.append(queryFilter.finish())
        return output
    }
}
