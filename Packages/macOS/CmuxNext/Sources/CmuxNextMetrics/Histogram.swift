/// Bucket math of the histogram layouts and the expiry rule (plans/cmux-next/chrome-parity/p09-observability.md
/// section 3D, task 052).
///
/// Log-linear buckets split each power of two into four linear sub-buckets, so a percentile read from a
/// bucket's upper bound is at most 25% above the true sample. The index function is the Rust daemon's
/// (cmux-tui-core diagnostics.rs `LogLinearHistogram::bucket_index`, and task 131's metrics file): values 0 to 3
/// take buckets 0 to 3, then a value with highest bit `o` takes `o * 4` plus its next two bits, so buckets 4 to 7
/// are never used. The golden both languages test against is
/// cmux-tui/crates/cmux-trace/tests/fixtures/metrics-log-linear-golden.txt. Chrome's log buckets are the same
/// idea with a per-histogram table (base/metrics/histogram.cc `Histogram::InitializeBucketRanges`); a fixed
/// function lets the Rust writers and the app agree without a table in each file.
extension HistogramID.Layout {
    /// The sub-buckets per power of two of a log-linear layout, as a shift (Rust's `SUB_BUCKETS_LOG2`).
    public static let logLinearSubBucketsLog2 = 2

    /// The log-linear bucket of `value` (no overflow bucket: every `UInt64` has one).
    @inlinable @inline(__always)
    public static func logLinearIndex(_ value: UInt64) -> Int {
        if value < 4 { return Int(value) }
        let octave = 63 - value.leadingZeroBitCount
        return octave &* 4 &+ Int(truncatingIfNeeded: (value >> UInt64(octave - 2)) & 3)
    }

    /// The smallest value in log-linear bucket `index` (`index` from a value, so never 4 to 7; at most 255).
    public static func logLinearLowerBound(_ index: Int) -> UInt64 {
        guard index >= 4 else { return UInt64(max(index, 0)) }
        guard index < 256 else { return .max }
        let octave = UInt64(index / 4), sub = UInt64(index % 4)
        return (1 << octave) + sub * (1 << (octave - 2))
    }

    /// The largest value in log-linear bucket `index`; the top bucket ends at `UInt64.max` (Rust's
    /// `bucket_upper_bound`: (2^o - 1) + (sub + 1) * 2^(o-2) never overflows).
    public static func logLinearUpperBound(_ index: Int) -> UInt64 {
        guard index >= 4 else { return UInt64(max(index, 0)) }
        guard index < 256 else { return .max }
        let octave = UInt64(index / 4), sub = UInt64(index % 4)
        return ((1 << octave) - 1) + (sub + 1) * (1 << (octave - 2))
    }

    /// The buckets of a histogram with this layout, its overflow bucket included; 0 for Chromium's own layout,
    /// which cmux never records.
    public var bucketCount: Int {
        switch self {
        case let .logLinear(maximum): Self.logLinearIndex(UInt64(max(maximum, 0))) + 2
        case let .linear(maximum): Int(max(maximum, 0)) + 2
        case let .enumeration(valueCount): max(valueCount, 0) + 1
        case .chromium: 0
        }
    }

    /// The bucket `sample` counts in. A log-linear or linear sample below 0 counts as 0 and one above the
    /// maximum in the last (overflow) bucket; an enumeration value outside the list counts in the overflow
    /// bucket, as Chrome's `UMA_HISTOGRAM_ENUMERATION` does. Nil for Chromium's layout.
    public func bucketIndex(of sample: Int64) -> Int? {
        switch self {
        case let .logLinear(maximum):
            sample > maximum ? bucketCount - 1 : Self.logLinearIndex(UInt64(max(sample, 0)))
        case let .linear(maximum):
            sample > maximum ? bucketCount - 1 : Int(max(sample, 0))
        case let .enumeration(valueCount):
            sample >= 0 && sample < Int64(valueCount) ? Int(sample) : valueCount
        case .chromium: nil
        }
    }

    /// The samples bucket `index` holds, lowest to highest; the overflow bucket ends at `Int64.max`. Nil outside
    /// the layout, for a log-linear bucket no value takes (4 to 7) and for Chromium's layout.
    public func bucketRange(_ index: Int) -> ClosedRange<Int64>? {
        guard index >= 0, index < bucketCount else { return nil }
        switch self {
        case let .logLinear(maximum):
            if index == bucketCount - 1 { return (maximum + 1) ... Int64.max }
            if (4 ..< 8).contains(index) { return nil }
            let upper = min(Self.logLinearUpperBound(index), UInt64(maximum))
            return Int64(Self.logLinearLowerBound(index)) ... Int64(upper)
        case let .linear(maximum):
            return index == bucketCount - 1 ? (maximum + 1) ... Int64.max : Int64(index) ... Int64(index)
        case let .enumeration(valueCount):
            return index == valueCount ? Int64(valueCount) ... Int64.max : Int64(index) ... Int64(index)
        case .chromium:
            return nil
        }
    }
}

extension HistogramID.Expiry {
    /// Whether a build made on `day` records nothing for a histogram with this expiry (Chrome's `expires_after`,
    /// which tools/metrics/histograms/expired_histograms_array.py turns into a per-build list).
    public func hasExpired(builtOn day: MetricsProfile.Day) -> Bool {
        switch self {
        case .never: false
        case let .after(year, month, dayOfMonth): day > MetricsProfile.Day(year: year, month: month, day: dayOfMonth)
        }
    }
}

extension HistogramID {
    /// Whether a build made on `day` records this histogram: not expired, and not one of Chromium's own (those are
    /// read from Chromium, never recorded here).
    public func records(builtOn day: MetricsProfile.Day) -> Bool {
        layout != .chromium && !expiry.hasExpired(builtOn: day)
    }
}
