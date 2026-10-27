/// The input latency report at one moment (``InputLatencyLedger/snapshot``): the fields the
/// opt-in nightly report carries as `input_latency[]` and `scroll_jank`, and `debug.input` shows.
///
/// Fields: `bucket_edges_ms`, `slots_received`, `slots_without_frame_update` (non-key slots dropped
/// as Chrome drops events with no `caused_frame_update`), `slots_dropped` (lost before the ledger:
/// ring, table or hand-off), `rows` (per kind, target, entrypoint, presentation source and display: `count`,
/// `total`, `stages`; the most frequent first), `scroll_jank` (frame counts and Chrome's
/// `Event.ScrollJank.*` histograms) and `interactions` (cmux's INP, ``InteractionLatency``). Enum
/// case names only: no user text.
public struct InputLatencySnapshot: Sendable, Equatable, Codable {
    /// One row: a kind, target, entrypoint, presentation source and display.
    public struct Row: Sendable, Equatable, Codable {
        public var kind: String
        public var target: String
        public var entrypoint: String
        public var presentationSource: String
        /// The display the row's inputs were presented on.
        public var display: InputDisplayClass
        /// Slots counted.
        public var count: UInt64
        /// Oldest OS event to presented frame.
        public var total: InputLatencyHistogramSnapshot
        /// The stages some slot reached, in declaration order: the time since the stage before.
        public var stages: [Stage]

        public init(kind: String, target: String, entrypoint: String, presentationSource: String,
                    display: InputDisplayClass = .unknown, count: UInt64, total: InputLatencyHistogramSnapshot,
                    stages: [Stage]) {
            self.kind = kind
            self.target = target
            self.entrypoint = entrypoint
            self.presentationSource = presentationSource
            self.display = display
            self.count = count
            self.total = total
            self.stages = stages
        }

        private enum CodingKeys: String, CodingKey {
            case kind, target, entrypoint, display, count, total, stages
            case presentationSource = "presentation_source"
        }
    }

    /// One stage's deltas.
    public struct Stage: Sendable, Equatable, Codable {
        public var stage: String
        public var histogram: InputLatencyHistogramSnapshot

        public init(stage: String, histogram: InputLatencyHistogramSnapshot) {
            self.stage = stage
            self.histogram = histogram
        }
    }

    /// Chrome's scroll jank counts.
    public struct ScrollJank: Sendable, Equatable, Codable {
        public var presentedFrames: UInt64
        public var delayedFrames: UInt64
        public var skippedFrames: UInt64
        /// Keyed by Chrome's histogram name (`Event.ScrollJank.DelayedFramesPercentage.FixedWindow`, ...).
        public var histograms: [String: ScrollJankHistogramSnapshot]

        public init(presentedFrames: UInt64, delayedFrames: UInt64, skippedFrames: UInt64,
                    histograms: [String: ScrollJankHistogramSnapshot]) {
            self.presentedFrames = presentedFrames
            self.delayedFrames = delayedFrames
            self.skippedFrames = skippedFrames
            self.histograms = histograms
        }

        private enum CodingKeys: String, CodingKey {
            case presentedFrames = "presented_frames"
            case delayedFrames = "delayed_frames"
            case skippedFrames = "skipped_frames"
            case histograms
        }
    }

    /// The person's interactions (cmux's INP, ``InteractionLatency/Summary``): the count, the
    /// longest, the longest after ignoring one for each 50, and the kind and target of the longest.
    public struct Interactions: Sendable, Equatable, Codable {
        public var count: UInt64
        public var worstMilliseconds: Double
        public var highPercentileMilliseconds: Double
        /// ``InteractionLatency/Kind/wireName`` of the longest, nil with none.
        public var kindOfWorst: String?
        /// The ``InputTarget`` case name of the longest, nil with none.
        public var targetOfWorst: String?

        public init(count: UInt64 = 0, worstMilliseconds: Double = 0, highPercentileMilliseconds: Double = 0,
                    kindOfWorst: String? = nil, targetOfWorst: String? = nil) {
            self.count = count
            self.worstMilliseconds = worstMilliseconds
            self.highPercentileMilliseconds = highPercentileMilliseconds
            self.kindOfWorst = kindOfWorst
            self.targetOfWorst = targetOfWorst
        }

        /// `summary`'s numbers in milliseconds and its kind and target by name.
        public init(_ summary: InteractionLatency.Summary) {
            self.init(count: summary.count, worstMilliseconds: summary.worstMs,
                      highPercentileMilliseconds: summary.highPercentileMs, kindOfWorst: summary.kindOfWorst?.wireName,
                      targetOfWorst: summary.targetOfWorst.map { String(describing: $0) })
        }

        private enum CodingKeys: String, CodingKey {
            case count
            case worstMilliseconds = "worst_ms"
            case highPercentileMilliseconds = "high_pct_ms"
            case kindOfWorst = "kind_of_worst"
            case targetOfWorst = "target_of_worst"
        }
    }

    public var bucketEdgesMilliseconds: [Double]
    public var slotsReceived: UInt64
    public var slotsWithoutFrameUpdate: UInt64
    public var slotsDropped: UInt64
    public var rows: [Row]
    public var scrollJank: ScrollJank
    public var interactions: Interactions

    public init(bucketEdgesMilliseconds: [Double], slotsReceived: UInt64, slotsWithoutFrameUpdate: UInt64,
                slotsDropped: UInt64, rows: [Row], scrollJank: ScrollJank, interactions: Interactions = Interactions()) {
        self.bucketEdgesMilliseconds = bucketEdgesMilliseconds
        self.slotsReceived = slotsReceived
        self.slotsWithoutFrameUpdate = slotsWithoutFrameUpdate
        self.slotsDropped = slotsDropped
        self.rows = rows
        self.scrollJank = scrollJank
        self.interactions = interactions
    }

    private enum CodingKeys: String, CodingKey {
        case bucketEdgesMilliseconds = "bucket_edges_ms"
        case slotsReceived = "slots_received"
        case slotsWithoutFrameUpdate = "slots_without_frame_update"
        case slotsDropped = "slots_dropped"
        case rows
        case scrollJank = "scroll_jank"
        case interactions
    }
}
