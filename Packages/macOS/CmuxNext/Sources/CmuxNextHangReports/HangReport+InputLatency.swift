/// Input latency field data in a hang report (hang-reports-DESIGN.md section 4,
/// "Input latency"): Chrome's field latency as distributions, never single events
/// (components/metrics, `EventLatency.*` UMA histograms; cc/metrics/event_metrics.h for the
/// row keys, cc/metrics/scroll_jank_dropped_frame_tracker.cc for `scroll_jank`). Numbers and
/// closed-set labels only.
extension HangReport {
    /// The most `input_latency` rows one report carries (the most frequent first).
    public static let maxInputLatencyRows = 64
    /// The largest scroll jank value kept for a missed-vsync histogram: Chrome's
    /// `kVsyncCountsMax` (scroll_jank_dropped_frame_tracker.cc), whose last bucket holds every
    /// larger value. Percentages stop at 100.
    public static let maxMissedVsyncs = 50

    /// One `input_latency[]` row: how long inputs of one kind, target, entrypoint and
    /// presentation source took on one kind of display, from the oldest OS event to the presented
    /// frame.
    public struct InputLatencyRow: Codable, Sendable, Equatable {
        /// An `InputEventKind` case name (`keyPress`, `scrollUpdate`, ...).
        public var kind: String
        /// An `InputTarget` case name (`terminal`, `chromiumPage`, ...).
        public var target: String
        /// An `InputEntrypoint` case name: `person` or `automation`.
        public var entrypoint: String
        /// An `InputPresentationSource` case name (`estimatedVsync`, `metalPresented`, ...).
        public var presentationSource: String
        /// The display the row's inputs were presented on.
        public var display: Display
        /// Inputs counted: the sum of ``buckets``.
        public var count: UInt64
        /// One count per edge of ``HangReport/inputLatencyBucketEdgesMs``, then one over the last edge.
        public var buckets: [UInt64]
        /// The longest input, in milliseconds (two decimals).
        public var maxMs: Double

        /// Makes the value from its parts.
        public init(kind: String, target: String, entrypoint: String, presentationSource: String, display: Display,
                    count: UInt64, buckets: [UInt64], maxMs: Double) {
            self.kind = kind
            self.target = target
            self.entrypoint = entrypoint
            self.presentationSource = presentationSource
            self.display = display
            self.count = count
            self.buckets = buckets
            self.maxMs = maxMs
        }

        private enum CodingKeys: String, CodingKey {
            case kind, target, entrypoint, display, count, buckets
            case presentationSource = "presentation_source"
            case maxMs = "max_ms"
        }
    }

    /// `scroll_jank`: Chrome's scroll jank counts of the person's scrolls.
    public struct ScrollJank: Codable, Sendable, Equatable {
        /// One emitted Chrome histogram: each value with how often it was emitted, by value.
        public struct Histogram: Codable, Sendable, Equatable {
            /// One value and its count.
            public struct Sample: Codable, Sendable, Equatable {
                public var value: Int
                public var count: UInt64

                /// Makes the value from its parts.
                public init(value: Int, count: UInt64) {
                    self.value = value
                    self.count = count
                }
            }

            /// Chrome's histogram name (`Event.ScrollJank.DelayedFramesPercentage.FixedWindow`, ...).
            public var name: String
            /// The emitted values.
            public var samples: [Sample]

            /// Makes the value from its parts.
            public init(name: String, samples: [Sample]) {
                self.name = name
                self.samples = samples
            }
        }

        /// Scroll frames counted.
        public var presentedFrames: UInt64
        /// Janky frames (Chrome's delayed frames).
        public var delayedFrames: UInt64
        /// Frames left out (a scroll's first frame, out of order or inconsistent times).
        public var skippedFrames: UInt64
        /// The emitted histograms, in Chrome's name order.
        public var histograms: [Histogram]

        /// Makes the value from its parts.
        public init(presentedFrames: UInt64, delayedFrames: UInt64, skippedFrames: UInt64, histograms: [Histogram]) {
            self.presentedFrames = presentedFrames
            self.delayedFrames = delayedFrames
            self.skippedFrames = skippedFrames
            self.histograms = histograms
        }

        /// Whether no scroll frame was counted and no histogram emitted.
        public var isEmpty: Bool {
            presentedFrames == 0 && skippedFrames == 0 && histograms.isEmpty
        }

        private enum CodingKeys: String, CodingKey {
            case presentedFrames = "presented_frames"
            case delayedFrames = "delayed_frames"
            case skippedFrames = "skipped_frames"
            case histograms
        }
    }

    /// `interaction_latency`: cmux's Interaction to Next Paint for the report period
    /// (web.dev/articles/inp): how many interactions the person made (a key press to
    /// its release, a click, a drag), the longest, the longest after ignoring one for each 50 (Chrome's
    /// high percentile, components/page_load_metrics/browser/responsiveness_metrics_normalization.cc),
    /// and the kind of the longest. Numbers and a closed kind only.
    public struct InteractionLatency: Codable, Sendable, Equatable {
        /// The kinds ``kindOfWorst`` may name (`InteractionLatency.Kind.wireName`).
        public static let kinds: Set<String> = ["key", "tap", "drag"]

        /// Interactions in the period.
        public var count: UInt64
        /// The longest interaction, in milliseconds (two decimals, at most one day).
        public var worstMs: Double
        /// The INP value: the longest after ignoring one for each 50, in milliseconds; at most ``worstMs``.
        public var highPctMs: Double
        /// `key`, `tap` or `drag`.
        public var kindOfWorst: String

        /// Makes the value from its parts.
        public init(count: UInt64, worstMs: Double, highPctMs: Double, kindOfWorst: String) {
            self.count = count
            self.worstMs = worstMs
            self.highPctMs = highPctMs
            self.kindOfWorst = kindOfWorst
        }

        private enum CodingKeys: String, CodingKey {
            case count
            case worstMs = "worst_ms"
            case highPctMs = "high_pct_ms"
            case kindOfWorst = "kind_of_worst"
        }
    }

    /// A row's `display`: the display its inputs were presented on.
    public struct Display: Codable, Sendable, Hashable {
        /// The highest refresh rate it runs at, in whole hertz (0 when unknown).
        public var refreshHz: Int
        /// Whether its refresh rate varies (ProMotion, adaptive sync): estimated presentation
        /// times on it are less exact.
        public var vrr: Bool

        /// Makes the value from its parts.
        public init(refreshHz: Int, vrr: Bool) {
            self.refreshHz = refreshHz
            self.vrr = vrr
        }

        private enum CodingKeys: String, CodingKey {
            case refreshHz = "refresh_hz"
            case vrr
        }
    }
}
