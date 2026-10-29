public import CmuxNextInputCore

/// Why Chromium's histograms could not be read (``CEFHistogramReader``).
public nonisolated enum CEFHistogramReadError: Error, Hashable, Sendable {
    /// Chromium has not started in this process: it has recorded nothing yet.
    case notStarted
    /// Chromium runs but no Chromium page is open: there is no DevTools session to ask.
    case noBrowser
    /// Chromium did not answer within the DevTools deadline.
    case timedOut
    /// Chromium answered with a protocol error (its JSON).
    case protocolError(String)
    /// The reply was not a `Browser.getHistograms` result.
    case malformedReply

    /// The report's `unavailable` value: a case name, never Chromium's text.
    var reportName: String {
        switch self {
        case .notStarted: "not_started"
        case .noBrowser: "no_browser"
        case .timedOut: "timed_out"
        case .protocolError: "protocol_error"
        case .malformedReply: "malformed_reply"
        }
    }
}

/// `debug.input` section `chromium`: Chromium's own input latency histograms next to
/// cmux's ledger rows. Chromium keeps one histogram set per browser process (base/metrics/statistics_recorder.h)
/// and `Browser.getHistograms` takes no target, so the rows combine every Chromium page, browser pages and agent
/// pane pages alike: their target is ``target``, never one of cmux's `chromiumPage` or `agentPane` slots. A bench
/// that compares one surface with cmux's slots inputs to that surface alone between `reset` and the read.
///
/// Fields: `rows` (``InputLatencySnapshot/Row``: kind, target ``target``, entrypoint `any` as Chromium
/// does not tell a person from automation, presentation source `chromium`, total and Chromium's top-level stage
/// breakdown in pipeline order on cmux's bucket edges), `scroll_jank` (Chrome's `Event.ScrollJank.*` as value
/// samples), `histograms` (every histogram read, sub-stages and every total variant too, Chromium's own count and
/// sum), `renderer_event_latency` and `unavailable` (``CEFHistogramReadError``'s name; `reset_<name>` after a
/// reset that could not read Chromium, until a reset can).
public nonisolated struct ChromiumInputHistograms: Sendable, Equatable, Encodable {
    /// One Chromium histogram as read.
    public nonisolated struct Histogram: Sendable, Equatable, Encodable {
        public var name: String
        /// Chromium's sample count.
        public var count: UInt64
        /// Chromium's sum, in the histogram's unit.
        public var sum: Int64
        public var unit: Unit
        /// A microsecond histogram on cmux's bucket edges; nil for a sample histogram.
        public var latency: InputLatencyHistogramSnapshot?
    }

    /// What a histogram counts.
    public nonisolated enum Unit: String, Sendable, Equatable, Encodable {
        /// Durations in microseconds (`EventLatency.*`, `Event.Latency.*`).
        case microseconds
        /// Plain values (`Event.ScrollJank.*`: percentages and vsync counts).
        case sample
    }

    public var rows: [InputLatencySnapshot.Row]
    /// Keyed by Chrome's histogram name (`Event.ScrollJank.DelayedFramesPercentage.FixedWindow`, ...).
    public var scrollJank: [String: ScrollJankHistogramSnapshot]
    public var histograms: [Histogram]
    /// Some `EventLatency.*` histogram had samples. Each renderer's compositor records them (cc's
    /// CompositorFrameReporter); false after input to a page means they did not reach the browser
    /// process, which `Browser.getHistograms` reads (a PL-cef-layer fork item).
    public var rendererEventLatency: Bool
    /// Why nothing was read (``CEFHistogramReadError``); nil when the read succeeded.
    public var unavailable: String?

    private enum CodingKeys: String, CodingKey {
        case rows
        case scrollJank = "scroll_jank"
        case histograms
        case rendererEventLatency = "renderer_event_latency"
        case unavailable
    }
}

nonisolated extension ChromiumInputHistograms {
    /// Chrome's scroll jank histograms cmux's ``ScrollJankTracker`` ports.
    static let scrollJankNames = Set(ScrollJankHistograms.Name.allCases.map(\.rawValue))

    /// The rows' target: every page of Chromium's browser process together. No ``InputTarget`` case has this
    /// name, so nothing joins these rows with one surface's slots.
    static let target = "chromiumProcess"

    /// Nothing read, and why.
    init(unavailable error: CEFHistogramReadError) {
        self.init(rows: [], scrollJank: [:], histograms: [], rendererEventLatency: false, unavailable: error.reportName)
    }

    /// Nothing read: the last reset could not read Chromium, so no read can say what came after it.
    init(resetFailed error: CEFHistogramReadError) {
        self.init(rows: [], scrollJank: [:], histograms: [], rendererEventLatency: false, unavailable: "reset_\(error.reportName)")
    }

    /// The report of `chromium`'s histograms. Names of no known family are left out; so is every
    /// total but the newest version of each (`TotalLatency2` over `TotalLatency`), so no sample counts twice.
    init(folding chromium: [CEFChromiumHistogram]) {
        var newestTotals: [String: (version: Int, kind: InputEventKind, histogram: CEFChromiumHistogram)] = [:]
        // Keyed by the stage's place in ``CEFEventLatencyName/pipelineStages``.
        var stages: [InputEventKind: [Int: InputLatencyHistogram]] = [:]
        var scrollJank: [String: ScrollJankHistogramSnapshot] = [:]
        var histograms: [Histogram] = []
        var rendererEventLatency = false
        for histogram in chromium {
            var summary = Histogram(name: histogram.name, count: UInt64(clamping: histogram.count), sum: histogram.sum,
                                    unit: .microseconds, latency: nil)
            if let name = CEFEventLatencyName(histogram.name) {
                rendererEventLatency = rendererEventLatency || histogram.count > 0
                if let version = name.totalVersion {
                    if (newestTotals[name.base]?.version ?? -1) < version {
                        newestTotals[name.base] = (version, name.kind, histogram)
                    }
                } else if let order = name.stageOrder {
                    stages[name.kind, default: [:]][order, default: InputLatencyHistogram()].add(histogram.microsecondLatency)
                }
                summary.latency = histogram.microsecondLatency.snapshot
            } else if histogram.name.hasPrefix("Event.Latency.ScrollUpdate.") {
                // It ends at swap begin, not at presentation: a histogram of its own, not a row.
                summary.latency = histogram.microsecondLatency.snapshot
            } else if Self.scrollJankNames.contains(histogram.name) {
                scrollJank[histogram.name] = ScrollJankHistogramSnapshot(samples: histogram.buckets.filter { $0.count > 0 }.map {
                    ScrollJankHistogramSnapshot.Sample(value: Int(clamping: $0.low), count: UInt64(clamping: $0.count))
                })
                summary.unit = .sample
            } else {
                continue
            }
            histograms.append(summary)
        }
        var totals: [InputEventKind: InputLatencyHistogram] = [:]
        for total in newestTotals.values {
            totals[total.kind, default: InputLatencyHistogram()].add(total.histogram.microsecondLatency)
        }
        let rows = totals.filter { $0.value.count > 0 }.map { kind, total in
            InputLatencySnapshot.Row(
                kind: String(describing: kind),
                target: Self.target,
                entrypoint: "any",
                presentationSource: "chromium",
                display: .unknown,
                count: total.count,
                total: total.snapshot,
                stages: (stages[kind] ?? [:]).sorted { $0.key < $1.key }.map {
                    InputLatencySnapshot.Stage(stage: CEFEventLatencyName.pipelineStages[$0.key], histogram: $0.value.snapshot)
                })
        }
        // The most frequent first, as the ledger orders its rows.
        self.init(rows: rows.sorted { $0.count != $1.count ? $0.count > $1.count : $0.kind < $1.kind },
                  scrollJank: scrollJank,
                  histograms: histograms.sorted { $0.name < $1.name },
                  rendererEventLatency: rendererEventLatency,
                  unavailable: nil)
    }
}
