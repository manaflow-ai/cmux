public import Foundation
public import MetricKit

/// Subscribes to MetricKit while hang reports are on and turns each delivery into a
/// ``MetricKitInput`` (typed values and the call stack trees' JSON; nothing else of a payload
/// is read). MetricKit calls it on its own queue, at most about once a day for metrics and
/// after a hang or CPU exception for diagnostics; it costs nothing between deliveries.
public final class MetricKitSubscriber: NSObject, MXMetricManagerSubscriber, Sendable {
    private let deliver: @Sendable (MetricKitInput) -> Void
    private let since: Date

    /// - Parameters:
    ///   - since: The person's consent time: payloads that began earlier (MetricKit keeps
    ///     undelivered ones and hands them over at the first subscription) are dropped.
    ///   - deliver: Receives each delivery (``HangReportService/receive(_:)``).
    public init(since: Date, deliver: @escaping @Sendable (MetricKitInput) -> Void) {
        self.since = since
        self.deliver = deliver
    }

    /// Starts receiving deliveries.
    public func start() { MXMetricManager.shared.add(self) }

    /// Stops receiving deliveries.
    public func stop() { MXMetricManager.shared.remove(self) }

    /// A MetricKit delivery (MetricKit's queue).
    public func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads where payload.timeStampBegin >= since {
            let input = Self.input(payload)
            if !input.isEmpty { deliver(input) }
        }
    }

    /// A MetricKit delivery (MetricKit's queue).
    public func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads where payload.timeStampBegin >= since {
            let hangs = (payload.hangDiagnostics ?? []).map {
                MetricKitInput.Hang(durationMs: Self.ms($0.hangDuration), callStackTree: $0.callStackTree.jsonRepresentation())
            }
            let cpu = (payload.cpuExceptionDiagnostics ?? []).map {
                MetricKitInput.CPUException(cpuMs: Self.ms($0.totalCPUTime), sampledMs: Self.ms($0.totalSampledTime),
                                            callStackTree: $0.callStackTree.jsonRepresentation())
            }
            let input = MetricKitInput(hangs: hangs, cpuExceptions: cpu)
            if !input.isEmpty { deliver(input) }
        }
    }

    static func input(_ payload: MXMetricPayload) -> MetricKitInput {
        var metrics = HangReport.Metrics()
        if let responsiveness = payload.applicationResponsivenessMetrics {
            metrics.hangTime = buckets(responsiveness.histogrammedApplicationHangTime)
        }
        if let launch = payload.applicationLaunchMetrics {
            metrics.launchFirstDraw = buckets(launch.histogrammedTimeToFirstDraw)
            metrics.launchResume = buckets(launch.histogrammedApplicationResumeTime)
            metrics.launchOptimizedFirstDraw = buckets(launch.histogrammedOptimizedTimeToFirstDraw)
            metrics.launchExtended = buckets(launch.histogrammedExtendedLaunch)
        }
        if let animation = payload.animationMetrics {
            metrics.scrollHitchMsPerS = animation.scrollHitchTimeRatio.value
            if #available(macOS 26.0, *) { metrics.hitchMsPerS = animation.hitchTimeRatio.value }
        }
        let signposts = (payload.signpostMetrics ?? []).map { metric in
            MetricKitInput.Signpost(category: metric.signpostCategory, name: metric.signpostName, count: metric.totalCount,
                                    buckets: metric.signpostIntervalData.map { buckets($0.histogrammedSignpostDuration) } ?? [],
                                    hitchMsPerS: metric.signpostIntervalData?.cumulativeHitchTimeRatio?.value)
        }
        return MetricKitInput(metrics: metrics, signposts: signposts)
    }

    static func buckets(_ histogram: MXHistogram<UnitDuration>) -> [HistogramBucket] {
        histogram.bucketEnumerator.compactMap { $0 as? MXHistogramBucket<UnitDuration> }.map { bucket in
            HistogramBucket(lowMs: ms(bucket.bucketStart), highMs: ms(bucket.bucketEnd), count: bucket.bucketCount)
        }
    }

    static func ms(_ measurement: Measurement<UnitDuration>) -> Int {
        let value = measurement.converted(to: .milliseconds).value
        return value.isFinite ? Int(min(max(value, 0), Double(HistogramBucket.maxMs))) : 0
    }
}
