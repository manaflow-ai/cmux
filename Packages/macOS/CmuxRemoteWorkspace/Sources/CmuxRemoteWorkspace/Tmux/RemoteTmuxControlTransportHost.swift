public import Foundation

/// Callback seam that ``RemoteTmuxControlTransport`` uses to hand the bytes and
/// lifecycle edges of its `ssh tmux -CC` subprocess back to its owning
/// `tmux -CC` control connection, without the transport referencing the app-only
/// parser, command FIFO, captured-stderr buffer, or connection-state machine.
///
/// The connection conforms and injects itself via
/// ``RemoteTmuxControlTransport/attach(host:)``. Every member carries only plain
/// `Data`/`String`, so the subprocess + pipe plumbing lives in this package while
/// the message parsing, session-gone classification, and reconnect decisions stay
/// app-side.
@MainActor
public protocol RemoteTmuxControlTransportHost: AnyObject {
    /// Delivers one raw stdout chunk from the control stream (feeds the app-side
    /// parser, in order).
    func transportDidReceiveStdoutChunk(_ data: Data)

    /// Signals that the stdout stream finished (process exit or reader EOF). Awaited
    /// so the connection can drain stderr before classifying a failed reconnect.
    func transportStreamDidEnd() async

    /// Delivers one decoded, non-empty stderr text fragment (appended app-side to the
    /// bounded captured-stderr buffer used for session-gone classification).
    func transportDidReceiveStderrText(_ text: String)

    /// Signals that a stdin write failed (broken pipe or closed SSH child), so the
    /// connection can reconnect from a clean slate.
    func transportStdinWriteDidFail()

    /// Signals that the bounded stdout hand-off buffer overflowed (the parser fell too
    /// far behind the SSH pipe), so the connection reconnects instead of dropping
    /// control-mode bytes.
    func transportStdoutBackpressureDidOverflow()
}
