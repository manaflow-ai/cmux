public import CmuxTerminalStream
public import Foundation

/// One event of an open terminal source, in channel order.
public enum TerminalSourceEvent: Sendable {
    /// `.host` only: one `terminal_bytes` frame (live bytes, `snapshot_ready`,
    /// `snapshot_history` or `digest`). The first frame after `open` is
    /// `snapshot_ready`.
    case frame(TerminalFrame)
    /// `.local` only: raw PTY output (for SSH, channel data in order).
    case bytes(Data)
    /// `.host` only: the canonical grid from size-state. A grid change is
    /// followed by a `snapshot_ready` frame of the same generation.
    case grid(cols: Int, rows: Int, generation: UInt32)
    /// `.host` only: the host throttled the `snapshot_request` named by `requestID`.
    case snapshotThrottled(retryAfterMilliseconds: Int, requestID: String)
    /// The window title the remote side set, when the source knows it apart
    /// from the byte stream (the renderer also reads OSC titles).
    case title(String)
    /// The current path and its round-trip time.
    case path(TerminalPath, rttMilliseconds: Double?)
    /// Another participant closed this viewer.
    case kicked(byDisplayName: String)
    /// The source ended; the stream finishes after this event.
    case closed(reason: String)
}
