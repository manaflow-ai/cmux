/// The arithmetic of the remote stream's present metrics: which host frames the viewer showed, for
/// `smoothness.dropped_pct.remote_stream`, and which inputs a shown frame shows for the first time, for
/// `remote.input_to_present`. A value: ``RemotePresentLog`` owns one on the render queue.
///
/// Dropped frames follow Chrome's `FrameSequenceMetrics` (cc/metrics/frame_sequence_metrics.cc): a window of
/// expected frames against the frames presented, reported only once it has ``windowFrames`` frames (Chrome's
/// `kMinFramesForThroughputMetric`). A remote stream is damage driven, so the expected frames are the host's
/// frame numbers, not display refreshes: a frame lost on the network, skipped while decode waits for a keyframe,
/// replaced in the latest-frame mailbox or never shown by the display counts as dropped, and a still screen
/// expects nothing. A jump of more than ``windowFrames`` (a new stream, or one resumed after its pane was hidden)
/// starts a new sequence, as Chrome starts a new tracker, and drops the open window unreported.
nonisolated struct RemoteStreamPresentLedger: Sendable, Equatable {
    /// Host frames per reported window.
    static let windowFrames: UInt32 = 100

    /// The first host frame of the open window; nil before the first frame.
    private var windowStart: UInt32?
    /// The newest host frame seen.
    private var newest: UInt32 = 0
    /// Frames of the open window that the display showed.
    private var shownInWindow: UInt32 = 0
    /// The newest input sequence a shown frame has shown; 0 before any.
    private var lastShownInput: UInt32 = 0

    /// Counts host frame `frame` as shown by the display (`shown`) or not.
    ///
    /// - Returns: The window's percent of dropped frames, rounded, when this frame fills a window; else nil.
    mutating func frameCompleted(_ frame: UInt32, shown: Bool) -> Int64? {
        guard let start = windowStart else { return startSequence(at: frame, shown: shown) }
        let ahead = Int64(Int32(bitPattern: frame &- newest))
        if abs(ahead) > Int64(Self.windowFrames) { return startSequence(at: frame, shown: shown) }
        // Late: its window was already reported.
        if Int32(bitPattern: frame &- start) < 0 { return nil }
        if ahead > 0 { newest = frame }
        if shown { shownInWindow += 1 }
        return closeFullWindow()
    }

    /// The inputs a shown frame that echoes input `echo` shows for the first time: every sequence after the last
    /// one shown, up to `echo`, at most ``RemoteInputLatency/capacity`` of them (older ones left the send table).
    /// Nil when `echo` is 0 (the host does not say) or not newer than what was already shown.
    mutating func newlyShownInputs(echo: UInt32) -> ClosedRange<UInt32>? {
        guard echo > lastShownInput else { return nil }
        let window = UInt32(RemoteInputLatency.capacity)
        let lower = max(lastShownInput + 1, echo > window ? echo - window + 1 : 1)
        lastShownInput = echo
        return lower...echo
    }

    private mutating func startSequence(at frame: UInt32, shown: Bool) -> Int64? {
        windowStart = frame
        newest = frame
        shownInWindow = shown ? 1 : 0
        return closeFullWindow()
    }

    private mutating func closeFullWindow() -> Int64? {
        guard let start = windowStart else { return nil }
        let expected = newest &- start &+ 1
        guard expected >= Self.windowFrames else { return nil }
        let dropped = expected - min(shownInWindow, expected)
        windowStart = newest &+ 1
        shownInWindow = 0
        return (Int64(dropped) * 100 + Int64(expected) / 2) / Int64(expected)
    }
}
