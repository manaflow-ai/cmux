/// The frame a pointer delivery is drawn in: the `frame_time` Chromium hands to
/// `MainThreadEventQueue::DispatchRafAlignedInput` and to its resampler
/// (`third_party/blink/renderer/platform/widget/input/main_thread_event_queue.cc`,
/// `ui/base/prediction/linear_resampling.cc`). Times are seconds since boot, the clock of
/// ``InputEventRecord/timestamp`` and of the display link (both `mach_absolute_time`).
public struct PointerFrameTime: Hashable, Sendable {
    /// The frame's time: the display link's time when a frame tick delivers; the newest event's own
    /// time when the delivery goes out at once (a leading edge, a flush before discrete input, the
    /// fallback timer), because no frame has begun for it.
    public var time: Double
    /// The display's refresh interval in seconds, as last ticked.
    public var interval: Double

    public init(time: Double, interval: Double) {
        self.time = time
        self.interval = interval
    }
}
