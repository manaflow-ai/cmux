/// An open ``SignpostName/stallMainTask`` interval returned by ``Signposter/begin(_:taskClass:owner:classID:ownerID:)``;
/// end it exactly once, on the same thread, with the ``MainTaskInterval`` overload of `Signposter.end(_:_:)`. A plain
/// value (the signpost id, the begin time and the ring slice): the scheduler opens one per task, so a task holds no
/// heap state, unlike ``SignpostInterval``'s `OSSignpostIntervalState`. Never mirrored to MetricKit (the `stall`
/// category, ``SignpostMetricKitMirror/mirrors(_:)``).
public nonisolated struct MainTaskInterval {
    /// The interval's `os_signpost_id_t` on the stall log.
    let id: UInt64
    /// `CLOCK_UPTIME_RAW` nanoseconds when the task began (the trace ring's clock).
    public let beginUptimeNanos: UInt64
    /// The trace ring slice the begin opened (a thread slice), or nil when the stall category was off then.
    let ring: SignpostInterval.Ring?

    /// Whether the begin wrote a trace ring record (its end writes one too).
    public var isTraced: Bool { ring != nil }
}
