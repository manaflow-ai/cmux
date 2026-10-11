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
///
/// The replay omits DECSCUSR: the cursor shape it reports is restored before
/// the pending bytes, unless it is the user's own default
/// (``TerminalCursorDefault``). A stream's end is not a terminal exit here:
/// the attach machine decides between disconnected and exited.
public nonisolated enum TerminalStreamPlan {
    public enum Step: Sendable, Equatable {
        /// Canonical grid for the mirror, ordered with the byte stream.
        case grid(columns: Int, rows: Int)
        /// Full screen state for a fresh mirror.
        case replay(TerminalReplay)
        /// GHOSTSNP restore on the live mirror: `ready` replaces its state
        /// (preceded by its grid), `history` adds that READY's scrollback.
        case snapshot(TerminalSnapshotFrame)
        case output(Data)
        /// The terminal's process is gone.
        case exited
        /// The view's link changed (disconnected, reconnecting, back).
        case status(TerminalLinkStatus)
    }

    public static func steps(for event: TerminalChannelEvent, cursorDefault: TerminalCursorDefault = .ghostty) -> [Step] {
        switch event {
        case .replay(let replay):
            [.grid(columns: replay.cols, rows: replay.rows), .replay(replay)]
                + tail(replay, cursorDefault: cursorDefault)
        case .resized(let replay):
            [.grid(columns: replay.cols, rows: replay.rows)]
        case .output(let data, _):
            [.output(data)]
        case .closed, .colorsChanged, .scrollChanged:
            []
        case .snapshot(let frame):
            // The decoder admits a READY only with its grid. A local-history
            // READY locks no grid first: its restore reflows the old grid.
            if frame.phase == .ready, frame.localHistory == nil, let cols = frame.cols, let rows = frame.rows {
                [.grid(columns: cols, rows: rows), .snapshot(frame)]
            } else {
                [.snapshot(frame)]
            }
        }
    }

    /// Cursor shape, then the unfinished sequence, written after a replay.
    private static func tail(_ replay: TerminalReplay, cursorDefault: TerminalCursorDefault) -> [Step] {
        var bytes = cursorDefault.restore(style: replay.colors?.cursorStyle, blink: replay.colors?.cursorBlink)
        bytes.append(replay.pending)
        return bytes.isEmpty ? [] : [.output(bytes)]
    }
}
