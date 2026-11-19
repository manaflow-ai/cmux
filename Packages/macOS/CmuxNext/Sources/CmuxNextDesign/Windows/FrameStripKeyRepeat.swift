#if DEBUG || CMUX_BENCH_HOOKS
/// When the later keys of one frame strip go in (`debug.new_tab {action: "frame_strip"}` with `repeat`).
///
/// A key's own work runs inside its send. A person's second key does not come later because that work is long, so
/// a later key is due a whole number of intervals after the first key WENT IN, not after the key before it returned:
///
/// ```swift
/// let keys = FrameStripKeyRepeat(intervalMilliseconds: 100)
/// keys.delay(beforeKey: 1, elapsed: .milliseconds(34))  // 66 ms: the first key's work took 34 of the 100
/// ```
public nonisolated struct FrameStripKeyRepeat: Sendable, Equatable {
    /// The time between two keys (1 ms at least).
    public let interval: Duration

    /// The keys of a strip whose `repeat_interval_ms` is `intervalMilliseconds`.
    ///
    /// - Parameter intervalMilliseconds: The strip's `repeat_interval_ms`; 40 ms when the caller gave none.
    public init(intervalMilliseconds: Double?) {
        interval = .milliseconds(max(1, Int(intervalMilliseconds ?? 40)))
    }

    /// The time from now to a later key, asked when the key before it returned from its send.
    ///
    /// - Parameters:
    ///   - index: The key: 1 is the second key of the strip.
    ///   - elapsed: The time since the first key went in (taken before that key's own work).
    /// - Returns: The time from now at which the key goes in: zero when it is due already (the keys before it took longer).
    public func delay(beforeKey index: Int, elapsed: Duration) -> Duration {
        max(.zero, interval * index - elapsed)
    }
}
#endif
