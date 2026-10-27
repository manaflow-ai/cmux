public import CmuxNextTrace

/// Records field-histogram samples into the process's metrics file (Chrome's `UMA_HISTOGRAM_*` macros
/// over `base::GlobalHistogramAllocator`, base/metrics/persistent_histogram_allocator.h).
///
/// A record is three relaxed atomic adds (bucket, count, sum) into the runtime's ``MetricsStore``, whose
/// counters live in a per-launch `MAP_SHARED` file after startup, with no lock, allocation or system call,
/// so it is safe on the main thread and on any lane (p09-observability.md section 3D). An expired id, and
/// any id while the runtime has no store, records nothing.
///
/// ```swift
/// Metrics().record(.keyFrame(.view), 3_200)
/// ```
public struct Metrics: Sendable {
    /// The runtime whose metrics file the samples go to.
    public let runtime: TraceRuntime

    /// A recorder for `runtime`'s process (the app's by default; tests pass their own).
    public init(runtime: TraceRuntime = .shared) {
        self.runtime = runtime
    }

    /// Records one sample of `id`, in the id's ``HistogramID/unit`` (an enumeration's value, a count of 1,
    /// a duration in us or ms, a size in KiB, a percent).
    // perf-hot: 200ns metrics-record
    public func record(_ id: HistogramID, _ sample: Int64) {
        guard let store = runtime.attachedMetrics else { return }
        store._withUnsafeGuaranteedRef { unsafeDowncast($0, to: MetricsStore.self).record(id, sample) }
    }

    /// Records a duration sample of `id`, converted to the id's unit (us or ms).
    public func record(_ id: HistogramID, duration: Duration) {
        let (seconds, attoseconds) = duration.components
        let micros = seconds &* 1_000_000 &+ attoseconds / 1_000_000_000_000
        record(id, id.unit == .milliseconds ? micros / 1_000 : micros)
    }
}

extension HistogramID {
    /// What a histogram's samples count.
    public enum Unit: Sendable, Equatable {
        /// A duration in microseconds.
        case microseconds
        /// A duration in milliseconds.
        case milliseconds
        /// A size in KiB.
        case kibibytes
        /// A percent, 0 to 100.
        case percent
        /// A count of events.
        case count
        /// A value of a fixed list (the family's doc comment names the list).
        case enumeration
        /// Chromium's own unit and buckets (read from Chromium, never recorded by cmux).
        case chromium
    }

    /// How samples map to buckets.
    public enum Layout: Sendable, Equatable {
        /// Values 0 to 3 take buckets 0 to 3, then 4 buckets per power of two (buckets 4 to 7 stay empty) up
        /// to `maximum`; larger values go to the last bucket (an overflow bucket). Histogram.swift has the math.
        case logLinear(maximum: Int64)
        /// One bucket per value from 0 to `maximum`, plus an overflow bucket.
        case linear(maximum: Int64)
        /// One bucket per value from 0 to `valueCount - 1`, plus an overflow bucket.
        case enumeration(valueCount: Int)
        /// Chromium's buckets, as Chromium reports them.
        case chromium
    }

    /// When a histogram stops recording.
    public enum Expiry: Sendable, Equatable {
        /// It never expires (latency, launch, hang and stability histograms).
        case never
        /// It records nothing in builds made after this date, unless its owner renews it.
        case after(year: Int, month: Int, day: Int)
    }
}
