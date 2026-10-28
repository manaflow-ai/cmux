import CmuxNextCompat

/// Chromium's own histograms in the app's store (task 107): the deltas a harvest read from Chromium's
/// `base::StatisticsRecorder` (the fork's `cmux_cef_histogram_snapshot`), added up per histogram in Chromium's
/// buckets. They have no block in the metrics file: Chromium keeps its own numbers, so a crash loses only what
/// was harvested and not yet sent. A delta lists them as ``HistogramID/Layout/chromium`` histograms whose bucket
/// index is the bucket's smallest sample, as the hang report wire sends them.
extension MetricsStore {
    /// One Chromium bucket of a harvested delta: `count` samples from `minimum` up to Chromium's next bucket.
    public struct ChromiumBucket: Sendable, Equatable {
        /// The bucket's smallest sample (Chromium's `min`).
        public var minimum: Int64
        /// Its new samples.
        public var count: UInt64

        /// Makes the value from its parts.
        public init(minimum: Int64, count: UInt64) {
            self.minimum = minimum
            self.count = count
        }
    }

    /// Adds a harvested delta of `id` (samples Chromium recorded since the last harvest) under the shadow lock.
    /// False when `id` has expired in this build (``HistogramID/Expiry``), which keeps nothing.
    @discardableResult
    public func foldChromium(_ id: HistogramID.Chromium, count: UInt64, sum: UInt64, buckets: [ChromiumBucket]) -> Bool {
        guard !HistogramID.chromium(id).expiry.hasExpired(builtOn: profile.buildDay) else { return false }
        shadow.withLock { state in
            state.chromium.add(id, count: count, sum: sum, buckets: buckets)
        }
        return true
    }
}

/// Chromium's folded histograms and the part of each a report already sent, under ``MetricsStore``'s shadow lock.
struct ChromiumCounts: Sendable {
    /// A histogram's samples in Chromium's buckets, by each bucket's smallest sample.
    struct Counts: Sendable {
        var count: UInt64 = 0
        var sum: UInt64 = 0
        var buckets: [Int64: UInt64] = [:]
    }

    private(set) var totals: [HistogramID.Chromium: Counts] = [:]
    private var logged: [HistogramID.Chromium: Counts] = [:]

    /// Adds a delta; a bucket below 0 counts at 0, as a cmux sample below 0 does.
    mutating func add(_ id: HistogramID.Chromium, count: UInt64, sum: UInt64, buckets: [MetricsStore.ChromiumBucket]) {
        var counts = totals[id] ?? Counts()
        counts.count &+= count
        counts.sum &+= sum
        for bucket in buckets where bucket.count > 0 {
            counts.buckets[max(bucket.minimum, 0), default: 0] &+= bucket.count
        }
        totals[id] = counts
    }

    /// Every histogram with a sample, in catalog order: what was not marked logged yet (`unloggedOnly`), or all.
    func histograms(unloggedOnly: Bool) -> [MetricsDelta.Histogram] {
        HistogramID.Chromium.allCases.compactMap { id -> MetricsDelta.Histogram? in
            guard let total = totals[id] else { return nil }
            let sent = unloggedOnly ? logged[id] ?? Counts() : Counts()
            let count = total.count &- sent.count
            guard count != 0 else { return nil }
            let buckets = total.buckets.keys.sorted().compactMap { minimum -> MetricsDelta.Bucket? in
                let samples = total.buckets[minimum, default: 0] &- sent.buckets[minimum, default: 0]
                return samples == 0 ? nil : MetricsDelta.Bucket(index: Int(clamping: minimum), count: samples)
            }
            return MetricsDelta.Histogram(name: HistogramID.chromium(id).name, layout: .chromium, count: count,
                                          sum: total.sum &- sent.sum, buckets: buckets, entry: Self.entry)
        }
    }

    /// Adds the Chromium histograms of an uploaded `delta` (from ``histograms(unloggedOnly:)``) to the logged part.
    mutating func markLogged(_ delta: MetricsDelta) {
        for histogram in delta.histograms where histogram.entry == Self.entry && histogram.layout == .chromium {
            guard let id = Self.id(named: histogram.name), totals[id] != nil else { continue }
            var sent = logged[id] ?? Counts()
            sent.count &+= histogram.count
            sent.sum &+= histogram.sum
            for bucket in histogram.buckets {
                sent.buckets[Int64(truncatingIfNeeded: bucket.index), default: 0] &+= bucket.count
            }
            logged[id] = sent
        }
    }

    /// The directory position of a Chromium histogram: none (no image has it), so an image's
    /// ``MetricsImage/markLogged(_:)`` leaves it alone.
    static let entry = -1

    /// The Chromium id of a catalog name (`chromium.` and the UMA name).
    static func id(named name: String) -> HistogramID.Chromium? {
        let prefix = "chromium."
        guard name.hasPrefix(prefix) else { return nil }
        return HistogramID.Chromium(rawValue: String(name.dropFirst(prefix.count)))
    }
}
