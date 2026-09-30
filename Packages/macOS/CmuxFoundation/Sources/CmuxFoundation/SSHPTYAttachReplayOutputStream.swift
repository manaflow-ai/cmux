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

    /// Ends the replay hold after the caller's replay deadline expired.
    ///
    /// The deadline exists so a slow or lying peer cannot hold keystrokes
    /// forever; afterwards ``progress`` reports the replay as complete and
    /// input forwarding may start. The declared replay is still historical
    /// output, so the query filter keeps counting it down: a query in replay
    /// bytes that arrive late is stripped rather than answered into the live
    /// remote shell. ``SSHPTYReplayOutputFilter`` caps how many bytes it
    /// treats as replay, so an inflated declaration cannot hide live queries
    /// indefinitely.
    ///
    /// - Parameter discardingPendingReplay: Drop an unvalidated replay prefix
    ///   candidate because another managed attempt will follow. Pass the
    ///   decision later given to ``finish(discardingPendingReplay:)``: this
    ///   call clears the candidate, so that one can no longer drop it.
    /// - Returns: Buffered replay output that must still reach the terminal.
    public mutating func endStalledReplay(discardingPendingReplay: Bool = false) -> Data {
        queryFilter.filter(progress.endReplay(discarding: discardingPendingReplay))
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
