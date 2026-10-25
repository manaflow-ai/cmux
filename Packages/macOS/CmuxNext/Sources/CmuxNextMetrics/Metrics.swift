public import CmuxNextTrace

/// Records field-histogram samples into the process's metrics file (Chrome's `UMA_HISTOGRAM_*` macros
/// over `base::GlobalHistogramAllocator`, base/metrics/persistent_histogram_allocator.h).
///
/// A record will be three relaxed atomic adds into a per-launch `MAP_SHARED` file (bucket, count,
/// sum), with no lock, allocation or system call, so it is safe on the main thread and on any lane
/// (p09-observability.md section 3D). An expired id records nothing.
///
/// Stub (task 000): the signature is frozen; it records nothing until task 052 adds the store.
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
    public func record(_ id: HistogramID, _ sample: Int64) {
        // Task 052: bucket index from `id.layout`, then three relaxed adds.
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
        /// Bucket 0 holds values below 1, then 4 buckets per power of two up to `maximum`; larger values go
        /// to the last bucket (an overflow bucket).
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
