internal import CmuxNextCompat
internal import CmuxNextInputCore
internal import Foundation

/// One histogram of a `Browser.getHistograms` reply (protocol type `Browser.Histogram`,
/// content/browser/devtools/protocol/browser_handler.cc `Convert`): buckets are `[low, high)`, the
/// overflow one has `high` = INT_MAX (base/metrics/histogram_base.h `kSampleType_MAX`).
nonisolated struct CEFChromiumHistogram: Sendable, Equatable, Decodable {
    nonisolated struct Bucket: Sendable, Equatable, Decodable {
        var low: Int64
        var high: Int64
        var count: Int64
    }

    var name: String
    var sum: Int64
    var count: Int64
    var buckets: [Bucket]

    private nonisolated struct Reply: Decodable {
        var histograms: [CEFChromiumHistogram]
    }

    /// The histograms of one `Browser.getHistograms` result JSON.
    static func decodeReply(_ json: String) -> Result<[CEFChromiumHistogram], CEFHistogramReadError> {
        guard let reply = try? JSONDecoder().blockingDecode(Reply.self, from: Data(json.utf8)) else { return .failure(.malformedReply) }
        return .success(reply.histograms)
    }

    /// The samples recorded since `base`. A histogram with fewer samples than its baseline started over
    /// (a new Chromium host process): all of it is new.
    func subtracting(_ base: CEFChromiumHistogram?) -> CEFChromiumHistogram {
        guard let base, base.count <= count else { return self }
        var before: [Int64: Int64] = [:]
        for bucket in base.buckets { before[bucket.low, default: 0] += bucket.count }
        var delta = self
        delta.count = count - base.count
        delta.sum = sum - base.sum
        delta.buckets = buckets.compactMap { bucket in
            let added = bucket.count - (before[bucket.low] ?? 0)
            return added > 0 ? Bucket(low: bucket.low, high: bucket.high, count: added) : nil
        }
        return delta
    }

    /// The histogram on cmux's bucket edges. A Chromium bucket counts at its largest value
    /// (`high` - 1 µs; `low` for the overflow bucket), so a sample never moves to a faster cmux bucket
    /// and a percentile errs high by at most one Chromium bucket.
    var microsecondLatency: InputLatencyHistogram {
        var histogram = InputLatencyHistogram()
        for bucket in buckets where bucket.count > 0 {
            let micros = bucket.high >= Int64(Int32.max) ? bucket.low : max(bucket.low, bucket.high - 1)
            histogram.record(nanos: UInt64(clamping: micros) &* 1_000, count: UInt64(clamping: bucket.count))
        }
        return histogram
    }
}

/// The parts of an `EventLatency.<type>[.<device>].<metric>` name (cc/metrics/compositor_frame_reporter.cc,
/// `GetEventLatencyHistogramBaseName`): scroll and pinch types carry their input device, other types none.
nonisolated struct CEFEventLatencyName: Sendable, Equatable {
    /// Chromium's EventMetrics type names (cc/metrics/event_metrics.cc) cmux has a kind for, and whether
    /// the name carries a device (scroll and pinch types).
    static let types: [String: (kind: InputEventKind, device: Bool)] = [
        "KeyPressed": (.keyPress, false), "KeyReleased": (.keyRelease, false),
        "MousePressed": (.mousePress, false), "MouseReleased": (.mouseRelease, false),
        "MouseMoved": (.pointerMove, false), "MouseDragged": (.drag, false),
        "GestureScrollBegin": (.scrollBegin, true), "FirstGestureScrollUpdate": (.scrollFirstUpdate, true),
        "GestureScrollUpdate": (.scrollUpdate, true), "InertialGestureScrollUpdate": (.scrollMomentum, true),
        "GestureScrollEnd": (.scrollEnd, true),
        "GesturePinchBegin": (.magnify, true), "GesturePinchUpdate": (.magnify, true), "GesturePinchEnd": (.magnify, true),
    ]

    var kind: InputEventKind
    /// `EventLatency.<type>[.<device>]`: one Chromium base name.
    var base: String
    /// `TotalLatency`, `TotalLatency2`, or a stage of the breakdown.
    var metric: String

    /// Nil for a name of another family, a type cmux has no kind for, or a scroll or pinch name
    /// without its device (Chromium records none, so nothing counts twice).
    init?(_ name: String) {
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 3, parts[0] == "EventLatency", let type = Self.types[String(parts[1])] else { return nil }
        let metricStart = type.device ? 3 : 2
        guard parts.count > metricStart, parts.allSatisfy({ !$0.isEmpty }) else { return nil }
        kind = type.kind
        base = parts[..<metricStart].joined(separator: ".")
        metric = parts[metricStart...].joined(separator: ".")
    }

    /// The version of a total (`TotalLatency` 0, `TotalLatency2` 2); nil for a stage.
    var totalVersion: Int? {
        guard metric.hasPrefix("TotalLatency") else { return nil }
        let suffix = metric.dropFirst("TotalLatency".count)
        return suffix.isEmpty ? 0 : Int(suffix)
    }
}
