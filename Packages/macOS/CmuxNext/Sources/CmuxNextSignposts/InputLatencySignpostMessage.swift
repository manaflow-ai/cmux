/// The typed fields of one ``SignpostName/inputLatency`` event: one input event's stages, from its OS timestamp to
/// the frame that shows it, like Chrome's `EventMetrics` dispatch stages (cc/metrics/event_metrics.h).
///
/// Numbers only, so the log system formats them only when something reads them and nothing builds a `String` per
/// event. The kind, target, entrypoint and presentation source are the raw values of CmuxNextInputCore's
/// `InputEventKind`, `InputTarget`, `InputEntrypoint` and `InputPresentationSource` (this module does not import
/// it). Each stage is microseconds after ``generatedNanos``, or -1 when the stage was skipped (Chrome's empty
/// stage slot).
///
/// ```swift
/// Signposter(category: .input).event(.inputLatency, message)
/// ```
public nonisolated struct InputLatencySignpostMessage: Sendable, Hashable {
    /// `InputEventKind` raw value.
    public var kind: UInt8 = 0
    /// `InputTarget` raw value.
    public var target: UInt8 = 0
    /// `InputEntrypoint` raw value.
    public var entrypoint: UInt8 = 0
    /// `InputPresentationSource` raw value.
    public var presentationSource: UInt8 = 0
    /// The frame went to a variable-refresh display (a vsync estimate drifts there).
    public var variableRefresh = false
    /// OS events folded into this one (1 for an event that was not coalesced).
    public var coalescedCount: UInt32 = 1
    /// Whether the commit that ended the event's turn changed what is on screen (Chrome's `caused_frame_update`).
    public var causedFrameUpdate = false
    /// The oldest folded event's OS timestamp, `CLOCK_UPTIME_RAW` nanoseconds (the stage offsets' origin).
    public var generatedNanos: UInt64 = 0
    /// The newest folded event's OS timestamp.
    public var lastGeneratedMicros: Int64 = -1
    /// The event reached the main thread.
    public var arrivedMainMicros: Int64 = -1
    /// The app began dispatching it.
    public var dispatchStartMicros: Int64 = -1
    /// The input method server round trip began (`interpretKeyEvents`).
    public var textInputStartMicros: Int64 = -1
    /// The input method server round trip ended.
    public var textInputEndMicros: Int64 = -1
    /// The app's dispatch returned.
    public var dispatchEndMicros: Int64 = -1
    /// The Core Animation commit that ended the turn.
    public var mainCommitMicros: Int64 = -1
    /// The content process or renderer handed its frame to the render server (a terminal's IOSurface).
    public var contentSubmittedMicros: Int64 = -1
    /// The daemon received the key.
    public var daemonReceivedMicros: Int64 = -1
    /// The terminal host wrote it to the PTY.
    public var ptyWrittenMicros: Int64 = -1
    /// The terminal host read the echo.
    public var echoReadMicros: Int64 = -1
    /// The daemon sent the echo to the app.
    public var echoSentMicros: Int64 = -1
    /// The frame that shows the event reached the display (measured or estimated, ``presentationSource``).
    public var presentedMicros: Int64 = -1

    /// A message with every stage skipped.
    public init() {}

    /// The microseconds from `origin` to `nanos`, or -1 when `nanos` is 0 (a skipped stage).
    ///
    /// - Parameters:
    ///   - nanos: A stage's `CLOCK_UPTIME_RAW` time, 0 when skipped.
    ///   - origin: ``generatedNanos``.
    /// - Returns: The offset in microseconds (never below 0 for a recorded stage).
    public static func micros(_ nanos: UInt64, after origin: UInt64) -> Int64 {
        guard nanos != 0 else { return -1 }
        return nanos > origin ? Int64(truncatingIfNeeded: (nanos - origin) / 1_000) : 0
    }
}
