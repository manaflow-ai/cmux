/// Hands each blocking call site to several sinks, in order: the app's unified-log line
/// (``BlockingLogSink``) and its hang and crash reports both hear every site, since
/// ``BlockingDetector/install(sink:)`` keeps one sink and the last install wins.
///
/// ```swift
/// blocking.install(sink: BlockingSinkFanOut([BlockingLogSink(), reportSink]))
/// ```
public final class BlockingSinkFanOut: BlockingViolationSink {
    private let sinks: [any BlockingViolationSink]

    /// - Parameter sinks: The sinks each violation goes to, in this order.
    public init(_ sinks: [any BlockingViolationSink]) {
        self.sinks = sinks
    }

    /// Passes `violation` to every sink (on the detector's drain queue).
    public func record(_ violation: BlockingViolation) {
        for sink in sinks { sink.record(violation) }
    }
}
