/// A control client's observed control-mode state for `remote.tmux.state`,
/// the Sendable transfer twin of the app-side
/// `RemoteTmuxControlConnection.Snapshot`.
///
/// The app conformer reads this off the live connection; ``ControlRemoteTmuxWorker``
/// shapes it onto the wire exactly as the legacy `v2RemoteTmuxState` did
/// (including remapping `paneOutputByteCounts` keyed by integer pane id to the
/// `"%<id>"` wire keys, and emitting `session_id` only when present).
public struct ControlRemoteTmuxStateSnapshot: Sendable, Equatable {
    /// Whether the control client launched (the wire `started`).
    public let started: Bool

    /// Whether the `%begin … %end` enter handshake completed (`enter_received`).
    public let enterReceived: Bool

    /// Whether the control client exited (`exited`).
    public let exited: Bool

    /// tmux's numeric session id, when known; emitted as `session_id` only when
    /// present (the legacy `if let sessionId`).
    public let sessionId: Int?

    /// Number of windows observed (`window_count`).
    public let windowCount: Int

    /// The observed window ids (`window_ids`).
    public let windowIDs: [Int]

    /// Per-pane output byte counts keyed by integer pane id; remapped to
    /// `"%<id>"` keys on the wire (`pane_output_bytes`).
    public let paneOutputByteCounts: [Int: Int]

    /// Total observed output bytes (`total_output_bytes`).
    public let totalOutputBytes: Int

    /// Recent diagnostic event strings (`recent_events`).
    public let recentEvents: [String]

    /// Creates a remote-tmux state snapshot.
    ///
    /// - Parameters:
    ///   - started: Whether the control client launched.
    ///   - enterReceived: Whether the enter handshake completed.
    ///   - exited: Whether the control client exited.
    ///   - sessionId: tmux's numeric session id, when known.
    ///   - windowCount: Number of windows observed.
    ///   - windowIDs: The observed window ids.
    ///   - paneOutputByteCounts: Per-pane output byte counts by integer pane id.
    ///   - totalOutputBytes: Total observed output bytes.
    ///   - recentEvents: Recent diagnostic event strings.
    public init(
        started: Bool,
        enterReceived: Bool,
        exited: Bool,
        sessionId: Int?,
        windowCount: Int,
        windowIDs: [Int],
        paneOutputByteCounts: [Int: Int],
        totalOutputBytes: Int,
        recentEvents: [String]
    ) {
        self.started = started
        self.enterReceived = enterReceived
        self.exited = exited
        self.sessionId = sessionId
        self.windowCount = windowCount
        self.windowIDs = windowIDs
        self.paneOutputByteCounts = paneOutputByteCounts
        self.totalOutputBytes = totalOutputBytes
        self.recentEvents = recentEvents
    }
}
