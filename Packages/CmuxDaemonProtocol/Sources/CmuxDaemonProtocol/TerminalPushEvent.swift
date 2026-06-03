public import Foundation

/// A server-initiated event pushed by the daemon for a subscribed session.
///
/// Emitted by the daemon's dispatcher (outside the request/response flow) to
/// stream terminal output, end-of-file, and authoritative grid changes to the
/// client.
public enum TerminalPushEvent: Sendable {
    /// A window of terminal output, with optional inlined notification metadata.
    ///
    /// - Parameters:
    ///   - data: The output bytes.
    ///   - offset: The byte offset immediately past this data.
    ///   - baseOffset: The byte offset of the oldest retained data.
    ///   - truncated: Whether older data was truncated.
    ///   - eof: Whether the session reached end-of-file.
    ///   - seq: The daemon's monotonic event sequence number.
    ///   - notifications: Inlined notification metadata, if the output produced any.
    case output(
        data: Data,
        offset: UInt64,
        baseOffset: UInt64,
        truncated: Bool,
        eof: Bool,
        seq: UInt64,
        notifications: TerminalNotificationsPayload?
    )
    /// The session has reached end-of-file and will produce no further output.
    case eof
    /// The daemon-authoritative rendering grid.
    ///
    /// Emitted unconditionally by the daemon on every attach/resize/detach/open
    /// (and also inlined in RPC responses), so this is the single source of
    /// truth for how big the local surface should be. Clients apply it directly;
    /// any remaining container area is letterboxed.
    case viewSize(cols: Int, rows: Int)
}
