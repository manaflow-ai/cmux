public import CmuxNextDaemon
public import Foundation

/// Maps one daemon attach event to what a terminal view does with it.
///
/// The daemon's `resized` carries a full replay (cmux-tui-contract.md 2.5),
/// already reflowed at the new width. The Ghostty mirror never reflows: its
/// in-place resize clips rows and keeps their wrap flags (ghostty.h, "a mirror
/// never reflows"), so a pane that narrows would keep its old wide rows under
/// new output (manaflow-ai/cmux#12381). A `resized` replay therefore rebuilds
/// the mirror the same way the first replay of an attachment does: the grid,
/// then the replay on a fresh surface. Snapshot mode does not get `resized`
/// replays; its READY restores reflow the grid themselves.
///
/// A replay can end inside an escape sequence (`terminal-pending-sequence-v1`):
/// its unfinished bytes follow the replay as output, so the next live chunk
/// completes the sequence. This applies to a `resized` replay too: the fresh
/// surface has not parsed them.
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
        /// Who the grid is sized for, when another view sets it and it does not fit this one; nil
        /// clears it (plans/cmux-next/sync-ux/DESIGN.md 2.6).
        case sizing(TerminalSizeNotice?)
    }

    public static func steps(for event: TerminalChannelEvent, cursorDefault: TerminalCursorDefault = .ghostty) -> [Step] {
        switch event {
        case .replay(let replay), .resized(let replay):
            [.grid(columns: replay.cols, rows: replay.rows), .replay(replay)]
                + tail(replay, cursorDefault: cursorDefault)
        case .output(let data, _):
            [.output(data)]
        case .closed, .colorsChanged, .scrollChanged:
            []
        case .sizeState(let state, let participant):
            [.sizing(state.notice(for: participant))]
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
