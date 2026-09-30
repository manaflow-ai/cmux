public import CmuxNextDaemon
public import Foundation

/// Maps one daemon attach event to what a terminal view does with it.
///
/// The daemon's `resized` carries a full replay (cmux-tui-contract.md 2.5),
/// but the Ghostty mirror runs the same VT core and has parsed every byte up
/// to that point, so resizing it in place to the new grid reproduces the
/// daemon's reflow. The replay is dropped: feeding it would require a fresh
/// surface (Ghostty has no reset API) for every resize. Only the first replay
/// of an attachment, and a re-attach after overflow, rebuild the mirror.
///
/// A replay can end inside an escape sequence (`terminal-pending-sequence-v1`):
/// its unfinished bytes follow the replay as output, so the next live chunk
/// completes the sequence. A `resized` replay's pending bytes are dropped with
/// it: the mirror already parsed them from the live stream.
public nonisolated enum TerminalStreamPlan {
    public enum Step: Sendable, Equatable {
        /// Canonical grid for the mirror, ordered with the byte stream.
        case grid(columns: Int, rows: Int)
        /// Full screen state for a fresh mirror.
        case replay(TerminalReplay)
        case output(Data)
        /// The terminal's process is gone.
        case exited
    }

    public static func steps(for event: TerminalChannelEvent) -> [Step] {
        switch event {
        case .replay(let replay):
            [.grid(columns: replay.cols, rows: replay.rows), .replay(replay)]
                + (replay.pending.isEmpty ? [] : [.output(replay.pending)])
        case .resized(let replay):
            [.grid(columns: replay.cols, rows: replay.rows)]
        case .output(let data, _):
            [.output(data)]
        case .closed(.surfaceGone):
            [.exited]
        case .closed, .colorsChanged, .scrollChanged:
            []
        }
    }
}
