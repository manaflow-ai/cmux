import CmuxNextCompat
import CmuxNextMetrics
public import CmuxNextSettings
public import CmuxNextTrace
public import Foundation

/// `metrics.snapshot` (`cmux metrics`, View Metrics; plans/cmux-next/chrome-parity/p09-observability.md task 065):
/// the app's field histograms as JSON, read-only, served only while the `metricsView` feature is on.
extension ControlRouter {
    /// The `metrics.snapshot` method over `snapshot`'s store. It runs on the snapshot lane from the last published
    /// snapshot, so it answers while the main thread is stalled; its only parameter is `names`.
    ///
    /// - Parameters:
    ///   - snapshot: Reads the process's histograms (the app runtime's store by default; tests pass their own).
    ///   - enabled: Whether the `metricsView` feature is on; while it is off every request answers `unavailable`.
    public static func metricsMethod(_ snapshot: MetricsSnapshot = MetricsSnapshot(), enabled: Bool) -> ControlMethod {
        .snapshot(MetricsSnapshot.method) { call in
            guard enabled else {
                throw ControlError(code: "unavailable", message: ControlStrings.format(
                    "control.error.metricsOff", "%1$@ is off: turn on the feature %2$@ (CMUX_ENABLE_FEATURES=%2$@)",
                    MetricsSnapshot.method, "metricsView"))
            }
            return snapshot.json(names: try MetricsSnapshot.names(call.params))
        }.readingLastPublished()
    }
}

/// The local view of a process's field histograms: every sample recorded since launch, uploads or not, as JSON
/// (Chrome's chrome://histograms over `base::StatisticsRecorder::ToJSON`, base/metrics/statistics_recorder.cc, whose
/// `query` keeps the histograms whose name contains it). Each histogram has its name, unit, layout, count, sum and
/// non-empty buckets (`low`, `high`, `count`; the overflow bucket's `high` is null), with p50, p95, p99 and max read
/// from the buckets. Catalog names and numbers only: no path, URL, title or text.
///
/// ```swift
/// let json = MetricsSnapshot().json(names: ["key.frame"])
/// ```
public struct MetricsSnapshot: Sendable {
    /// The control method's name.
    public static let method = "metrics.snapshot"

    /// The runtime whose attached store is read.
    public let runtime: TraceRuntime

    /// A reader of `runtime`'s store (the app's by default; tests pass their own).
    public init(runtime: TraceRuntime = .shared) {
        self.runtime = runtime
    }

    /// The histograms with samples whose name contains one of `names` (every one when nil), in catalog order.
    /// `recording` is false while the runtime has no store. Takes the store's shadow lock for one read of the
    /// counters, so call it off the main thread.
    public func json(names: [String]? = nil) -> JSONValue {
        guard let store = MetricsStore.attached(to: runtime) else {
            return ["recording": false, "count": 0, "histograms": []]
        }
        let units = Dictionary(store.histograms.map { ($0.name, $0.unit) }, uniquingKeysWith: { first, _ in first })
        let shown = store.totals().histograms.filter { histogram in
            guard let names else { return true }
            return names.contains { name in histogram.name.contains(name) }
        }
        let profile = store.profile
        return [
            "recording": true,
            "pid": JSONValue(Int(clamping: store.pid)),
            "file_backed": .bool(store.isFileBacked),
            "profile": [
                "app_version": .string(profile.appVersion), "build": .string(profile.buildNumber),
                "channel": .string(profile.channel), "os_version": .string(profile.osVersion),
                "hardware_class": .string(profile.hardwareClass),
            ],
            "count": JSONValue(shown.count),
            "histograms": .array(shown.map { Self.json($0, unit: units[$0.name]) }),
        ]
    }

    /// Writes the JSON of every histogram to `file` (View Metrics), replacing it whole and making its folder.
    /// Blocking file work: BackgroundWork `.files`, never main.
    public func blockingWrite(to file: URL) throws {
        try FileManager.checked.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((json().prettyText() + "\n").utf8).blockingWrite(to: file, options: .atomic)
    }

    /// Why View Metrics cannot run while the `metricsView` feature is off.
    public static var featureOffReason: String {
        ControlStrings.text("control.metrics.viewOff", "View Metrics is off in this build. Turn on the metricsView feature to use it.")
    }

    /// The checked `names` of a request: nil for none (every histogram), else the substrings to match.
    ///
    /// - Throws: `invalid_params` for another parameter, or for `names` that is not an array of strings.
    public static func names(_ params: [String: JSONValue]) throws(ControlError) -> [String]? {
        if let unknown = params.keys.sorted().first(where: { $0 != "names" }) {
            throw ControlError.invalidParams(ControlStrings.format("control.error.unknownParam", "%1$@ does not take params.%2$@",
                                                                   method, unknown))
        }
        switch params["names"] ?? .null {
        case .null:
            return nil
        case .array(let items):
            let names = items.compactMap(\.stringValue)
            guard names.count == items.count else { break }
            return names.isEmpty ? nil : names
        default:
            break
        }
        throw ControlError.invalidParams(ControlStrings.format("control.error.metricsNamesShape", "%@ must be an array of strings",
                                                               "names"))
    }

    /// One histogram's JSON.
    static func json(_ histogram: MetricsDelta.Histogram, unit: HistogramID.Unit?) -> JSONValue {
        let layout = histogram.layout
        let overflow = layout.bucketCount - 1
        let overflowCount = histogram.buckets.first(where: { $0.index == overflow })?.count ?? 0
        let buckets: [JSONValue] = histogram.buckets.map { bucket in
            let range = layout.bucketRange(bucket.index)
            var low = JSONValue.null, high = JSONValue.null
            if let range {
                low = JSONValue(Int(truncatingIfNeeded: range.lowerBound))
                if bucket.index != overflow { high = JSONValue(Int(truncatingIfNeeded: range.upperBound)) }
            }
            return .object(["index": JSONValue(bucket.index), "low": low, "high": high, "count": .number(Double(bucket.count))])
        }
        var members: [String: JSONValue] = [
            "name": .string(histogram.name),
            "unit": unit.map { JSONValue.string(Self.name(of: $0)) } ?? .null,
            "layout": layoutJSON(layout),
            "count": .number(Double(histogram.count)),
            "sum": .number(Double(histogram.sum)),
            "mean": .number(Double(histogram.sum) / Double(max(histogram.count, 1))),
            "overflow_count": .number(Double(overflowCount)),
            "buckets": .array(buckets),
        ]
        // The values of an enumeration have no order: no percentiles.
        if case .enumeration = layout {} else {
            for (key, quantile) in [("p50", 0.5), ("p95", 0.95), ("p99", 0.99), ("max", 1.0)] {
                let value = Self.value(at: quantile, of: histogram)
                members[key] = value.map { JSONValue(Int(truncatingIfNeeded: $0)) } ?? JSONValue.null
            }
        }
        return .object(members)
    }

    /// The sample at `quantile` (above 0, at most 1), as the upper bound of the bucket that holds it: at most 25%
    /// above the true sample in a log-linear layout. In the overflow bucket it is that bucket's lower bound (the
    /// layout's maximum plus 1), which `overflow_count` flags. Nil without a bucket.
    static func value(at quantile: Double, of histogram: MetricsDelta.Histogram) -> Int64? {
        let rank = max(1, UInt64(exactly: (quantile * Double(histogram.count)).rounded(.up)) ?? histogram.count)
        var seen: UInt64 = 0
        // The counters are read one by one while writers add, so the buckets can sum to a little less than count.
        let reached = histogram.buckets.first(where: { bucket in
            seen &+= bucket.count
            return seen >= rank
        })
        let holding = reached ?? histogram.buckets.last
        guard let holding, let range = histogram.layout.bucketRange(holding.index) else { return nil }
        return holding.index == histogram.layout.bucketCount - 1 ? range.lowerBound : range.upperBound
    }

    private static func layoutJSON(_ layout: HistogramID.Layout) -> JSONValue {
        switch layout {
        case let .logLinear(maximum):
            return .object(["kind": .string("log_linear"), "maximum": JSONValue(Int(truncatingIfNeeded: maximum))])
        case let .linear(maximum):
            return .object(["kind": .string("linear"), "maximum": JSONValue(Int(truncatingIfNeeded: maximum))])
        case let .enumeration(valueCount):
            return .object(["kind": .string("enumeration"), "value_count": JSONValue(valueCount)])
        case .chromium:
            return .object(["kind": .string("chromium")])
        }
    }

    private static func name(of unit: HistogramID.Unit) -> String {
        switch unit {
        case .microseconds: "us"
        case .milliseconds: "ms"
        case .kibibytes: "KiB"
        case .percent: "percent"
        case .count: "count"
        case .enumeration: "enumeration"
        case .chromium: "chromium"
        }
    }
}
