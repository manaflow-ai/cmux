import CmuxNextCompat
public import Foundation

/// Chromium's own histograms in the app's store (task 107): the deltas a harvest read from Chromium's
/// `base::StatisticsRecorder` (the fork's `cmux_cef_histogram_snapshot`), added up per histogram in Chromium's
/// buckets, on the heap. Chromium's recorder ends with the app, so the quit harvests once more and
/// ``blockingSaveChromium(directory:)`` writes what no report sent beside this launch's metrics file; the next launch
/// reports it in this launch's section (``MetricsLaunchFileReader``), as Chrome's browser keeps its histograms in a
/// BrowserMetrics file for the next run (components/metrics/persistent_histograms.cc). A crash loses what was
/// recorded after the last harvest. A delta lists them as ``HistogramID/Layout/chromium`` histograms whose bucket
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

    /// `metrics-<role>-<pid>.chromium` beside the launch's metrics file `file`: the Chromium histograms that launch
    /// harvested and never sent.
    public static func chromiumFile(of file: URL) -> URL {
        file.deletingPathExtension().appendingPathExtension("chromium")
    }

    /// Writes the Chromium histograms no report sent yet beside this launch's metrics file in `directory` (the folder
    /// ``adoptFile(directory:)`` used), replacing an earlier write. False when nothing was written: the counters are on
    /// the heap (no earlier-launch section would carry them), every sample was sent, or the write failed. Blocking file
    /// work: the quit's files lane, never main.
    @discardableResult
    public func blockingSaveChromium(directory: URL) -> Bool {
        guard isFileBacked else { return false }
        let (launch, histograms) = shadow.withLock { state in
            (shadowImage(at: state.address)?.sourceLaunchID, state.chromium.histograms(unloggedOnly: true))
        }
        guard let launch, !histograms.isEmpty,
              let data = try? JSONEncoder().encode(ChromiumSavedHistograms(launch: launch, histograms: histograms)) else { return false }
        let file = Self.chromiumFile(of: directory.appending(path: Self.fileName(role: role, pid: pid), directoryHint: .notDirectory))
        do {
            try data.blockingWrite(to: file, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}

/// The Chromium histograms a launch saved at quit (``MetricsStore/blockingSaveChromium(directory:)``), for the launch
/// with id `launch` (``MetricsImage/sourceLaunchID``): a later launch that got the same pid has another id.
struct ChromiumSavedHistograms: Codable, Sendable {
    struct Histogram: Codable, Sendable {
        var name: String
        var count: UInt64
        var sum: UInt64
        /// (the bucket's smallest sample, its samples), ascending.
        var buckets: [Bucket]
    }

    struct Bucket: Codable, Sendable {
        var minimum: Int64
        var count: UInt64
    }

    var launch: String
    var histograms: [Histogram]

    init(launch: String, histograms: [MetricsDelta.Histogram]) {
        self.launch = launch
        self.histograms = histograms.map { histogram in
            Histogram(name: histogram.name, count: histogram.count, sum: histogram.sum,
                      buckets: histogram.buckets.map { Bucket(minimum: Int64($0.index), count: $0.count) })
        }
    }

    /// The saved histograms of the launch `launch` in `file`, as a delta lists them; none when the file is missing,
    /// does not decode or is another launch's. Blocking file work.
    static func blockingRead(_ file: URL, launch: String) -> [MetricsDelta.Histogram] {
        guard let data = try? Data(blockingContentsOf: file),
              let saved = try? JSONDecoder().decode(ChromiumSavedHistograms.self, from: data), saved.launch == launch else { return [] }
        return saved.histograms.compactMap { histogram -> MetricsDelta.Histogram? in
            guard ChromiumCounts.id(named: histogram.name) != nil, histogram.count > 0 else { return nil }
            let buckets = histogram.buckets.filter { $0.count > 0 }
                .map { MetricsDelta.Bucket(index: Int(clamping: max($0.minimum, 0)), count: $0.count) }
            return MetricsDelta.Histogram(name: histogram.name, layout: .chromium, count: histogram.count, sum: histogram.sum,
                                          buckets: buckets, entry: ChromiumCounts.entry)
        }
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
