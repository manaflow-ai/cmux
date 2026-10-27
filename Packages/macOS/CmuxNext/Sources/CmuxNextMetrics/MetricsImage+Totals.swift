import CmuxNextCompat

extension MetricsImage {
    /// Every sample the image counted, its logged shadow ignored, for each histogram with a sample: the local view's
    /// numbers (`metrics.snapshot`, View Metrics; task 065). An upload's ``markLogged(_:)`` does not lower them, as
    /// chrome://histograms shows `base::StatisticsRecorder`'s totals whatever UMA uploaded
    /// (base/metrics/statistics_recorder.cc `StatisticsRecorder::ToJSON`). Loads only.
    public func totals() -> MetricsDelta {
        var histograms: [MetricsDelta.Histogram] = []
        for (position, entry) in entries.enumerated() {
            let words = (base + entry.offset).assumingMemoryBound(to: UInt64.self)
            func current(_ word: Int) -> UInt64 { AtomicPointerSlot(words + word).load(ordering: .relaxed) }
            let count = current(0)
            guard count != 0 else { continue }
            var buckets: [MetricsDelta.Bucket] = []
            for index in 0 ..< entry.bucketCount {
                let samples = current(2 + index)
                if samples != 0 { buckets.append(MetricsDelta.Bucket(index: index, count: samples)) }
            }
            histograms.append(MetricsDelta.Histogram(name: entry.name, layout: entry.layout, count: count, sum: current(1),
                                                     buckets: buckets, entry: position))
        }
        return MetricsDelta(profile: profile, histograms: histograms)
    }
}
