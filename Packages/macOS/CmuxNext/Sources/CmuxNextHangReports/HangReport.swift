public import Foundation

/// One opt-in hang report, wire schema 2 (plans/cmux-next/hang-reports-DESIGN.md section 4), or
/// schema 3 with ``launches``, the input latency fields and the blocking detector's samples once the
/// server accepts it (``WireSchema``).
///
/// Every field is a closed set: enums, bucket labels, version numbers, durations, counts and
/// ``HangReportFrame`` values whose names passed ``ImageClassifier``. ``HangReportBuilder`` is the only
/// producer; ``PrivacyLeakScanner`` checks the encoded bytes before anything leaves the Mac.
///
/// ```swift
/// let report = builder.build(context: context, watchdog: collector.drain(), metricKit: inputs)
/// let body = try HangReport.encoder.encode(report)
/// ```
public nonisolated struct HangReport: Codable, Sendable, Equatable {
    /// The wire schemas a report can be written in. The server decodes strictly (unknown keys and
    /// values are a `400`, which drops the report from the outbox), so a client writes only a schema
    /// the deployed server accepts: ``WireSchema/deployed``.
    public enum WireSchema: Int, Codable, Sendable, CaseIterable {
        /// What the server accepts today (web/services/hangReports/wireSchema.ts): the same fields
        /// as 1, built with review 1 and 2's privacy fixes (Data-volume and `..` image paths are
        /// `other`, no redirects, per-Mac consent). The server refuses schema 1, so a report an
        /// older NIGHTLY queued is refused (and dropped from its outbox) once the endpoint opens.
        case v2 = 2
        /// Schema 2 plus ``HangReport/launches``, the input latency fields and the blocking
        /// detector's call sites: `hangs[]` may hold
        /// `{"source": "detector", "kind": "blocking", "durationMs": 0, "blocking": {"kind", "context"}}`
        /// samples (``HangSample/blockingSite(_:frames:)``). The server refuses unknown keys and
        /// other schema numbers, so a build writes it only after the server accepts it
        /// (p09-observability-064 deployed, behind p09-observability-063's server-version flag),
        /// and the field data: `histograms[]`,
        /// `stability{}`, `blackbox[]` and `launch_sections[]`.
        case v3 = 3

        /// The newest schema cmux.com's `web/services/hangReports/wireSchema.ts` accepts. It moves to
        /// ``v3`` only after that server change is deployed.
        public static let deployed = WireSchema.v2

        /// The schema this build writes: ``v3`` once the server-version feature (`hangReportsSchema3`, on
        /// after p09-observability-064 deployed) says the server accepts it, else ``deployed``.
        public static func written(serverAcceptsSchema3: Bool) -> WireSchema {
            serverAcceptsSchema3 ? .v3 : deployed
        }

        /// The largest body of this schema: schema 3's field data must fit 48 KiB
        /// (p09-observability.md section 3D), schema 2 keeps the 64 KiB the server accepts.
        public var maxBodyBytes: Int { self == .v3 ? 48 * 1024 : HangReport.maxBodyBytes }

        /// Whether a report in this schema carries ``HangReport/launches``.
        public var carriesLaunches: Bool { self == .v3 }
        /// Whether a report in this schema carries ``HangReport/inputLatency`` and
        /// ``HangReport/scrollJank``.
        public var carriesInputLatency: Bool { self == .v3 }
        /// Whether a report in this schema has blocking samples.
        public var carriesBlocking: Bool { self == .v3 }
        /// Whether a report in this schema carries ``CoarseCounts/userBlockingWaitP99Ms`` (the
        /// schema-3 decoder must list the key before a build sends schema 3).
        public var carriesLaneWait: Bool { self == .v3 }
        /// Whether a report in this schema carries ``HangReport/activeSeconds`` and the main-thread
        /// histograms (``HangReport/mainThreadCategory`` entries of ``HangReport/intervals``). The
        /// server's schema 3 decode accepts them in the PL-telemetry web PR that lands before a build
        /// writes schema 3.
        public var carriesMainThread: Bool { self == .v3 }
        /// Whether a watchdog hang sample carries ``HangSample/mainTask`` (`"task": {"owner", "class"}`,
        /// the schema-3 decoder must list the key before a build sends schema 3).
        public var carriesTaskAttribution: Bool { self == .v3 }
        /// Whether a watchdog stall or hang carries ``HangSample/startup`` (`"startup": {"phase", "task"}`,
        /// the schema-3 decoder must list the key before a build sends schema 3).
        public var carriesStartupTag: Bool { self == .v3 }
        /// Whether a report in this schema carries ``HangReport/histograms``, ``HangReport/stability``,
        /// ``HangReport/blackbox`` and ``HangReport/launchSections``.
        public var carriesFieldData: Bool { self == .v3 }
        /// Whether a report in this schema has the hang watch's samples of other threads
        /// (``HangSample/threadHang(_:durationMs:frames:)``: source `hangwatch`, kind `hang`, `"thread": {"name", "kind"}`;
        /// the schema-3 decoder lists them: web/services/hangReports/wireSchema.ts `HangV3`).
        public var carriesThreadHangs: Bool { self == .v3 }
        /// Whether a report in this schema carries ``HangReport/featuresHash`` and ``HangReport/features``
        /// (the schema-3 decoder lists them: web/services/hangReports/wireSchema.ts).
        public var carriesFeatures: Bool { self == .v3 }
        /// Whether a report in this schema carries ``HangReport/blockingSites``, the main thread's blocking call
        /// counts by site id (the schema-3 decoder lists them: web/services/hangReports/wireSchema.ts).
        public var carriesBlockingSites: Bool { self == .v3 }
    }

    /// The wire schema a report is written in by default (``WireSchema/deployed``).
    public static let schemaVersion = WireSchema.deployed.rawValue
    /// The most hangs and stalls one report carries.
    public static let maxHangs = 20
    /// The most CPU exceptions one report carries.
    public static let maxCPUExceptions = 5
    /// The most signpost intervals one report carries.
    public static let maxIntervals = 64
    /// The largest schema 2 body the server accepts (64 KiB); ``WireSchema/maxBodyBytes`` is each schema's.
    public static let maxBodyBytes = 64 * 1024
    /// The ``intervals`` category of the watchdog's main-thread histograms (schema 3 only): not a
    /// signpost category, so no MetricKit interval can use it (``HangReportSignposts/categories``).
    public static let mainThreadCategory = "main"
    /// The ``intervals`` name of the main-turn histogram: a run-loop wake to its next wait.
    public static let mainTurnInterval = "main.turn"
    /// The ``intervals`` name of the input-queueing histogram: an input's OS event time to its dispatch.
    public static let inputQueueingInterval = "main.input_queueing"
    /// The most active seconds one report names (31 days); a larger count is sent as this.
    public static let maxActiveSeconds = 31 * 86_400
    /// The most non-default features one report names.
    public static let maxFeatures = 64

    /// A launch's features as the app passes them (`CmuxNextFeatures`' `FeatureFieldState`): the hash of
    /// every feature's value and the features an input other than the channel default decided.
    public struct FeatureState: Sendable, Equatable {
        /// 16 lowercase hex digits.
        public var hash: String
        /// The features an override decided, sorted by name.
        public var nonDefault: [FeatureEntry]

        /// Makes the value from its parts.
        public init(hash: String, nonDefault: [FeatureEntry]) {
            self.hash = hash
            self.nonDefault = nonDefault
        }
    }

    /// One feature an override decided: its registry name, `on` or `off`, and the input that decided it
    /// (`policy`, `env`, `local`, `remote` or `trial`). Names only.
    public struct FeatureEntry: Codable, Sendable, Equatable {
        /// The registry name (`schemas/features/features.d/<name>.json`).
        public var name: String
        /// `on` or `off`.
        public var state: String
        /// The input that decided it.
        public var source: String

        /// Makes the value from its parts.
        public init(name: String, state: String, source: String) {
            self.name = name
            self.state = state
            self.source = source
        }
    }

    /// The app that wrote the report.
    public struct App: Codable, Sendable, Equatable {
        /// `CFBundleShortVersionString` (digits and dots).
        public var version: String
        /// `CFBundleVersion` (digits and dots).
        public var build: String
        /// `nightly`, `dev`, `rc` or `release`.
        public var channel: String

        /// Makes the value from its parts.
        public init(version: String, build: String, channel: String) {
            self.version = version
            self.build = build
            self.channel = channel
        }
    }

    /// The operating system, as `major.minor.patch` only.
    public struct OS: Codable, Sendable, Equatable {
        /// Digits and dots only.
        public var version: String

        /// Makes the value from its parts.
        public init(version: String) {
            self.version = version
        }
    }

    /// MetricKit's aggregated histograms and ratios (all optional: a report without a metric
    /// payload carries none).
    public struct Metrics: Codable, Sendable, Equatable {
        /// `MXAppResponsivenessMetric` hang-time histogram.
        public var hangTime: [HistogramBucket] = []
        /// Time to first draw (`MXAppLaunchMetric`).
        public var launchFirstDraw: [HistogramBucket] = []
        /// Resume time (`MXAppLaunchMetric`).
        public var launchResume: [HistogramBucket] = []
        /// Optimized time to first draw (`MXAppLaunchMetric`).
        public var launchOptimizedFirstDraw: [HistogramBucket] = []
        /// Extended launch time (`MXAppLaunchMetric`).
        public var launchExtended: [HistogramBucket] = []
        /// `MXAnimationMetric.scrollHitchTimeRatio`, milliseconds of hitch per second of scrolling.
        public var scrollHitchMsPerS: Double?
        /// `MXAnimationMetric.hitchTimeRatio` (macOS 26), milliseconds of hitch per second.
        public var hitchMsPerS: Double?

        /// Makes the value from its parts.
        public init() {}

        /// Whether no metric arrived.
        public var isEmpty: Bool {
            hangTime.isEmpty && launchFirstDraw.isEmpty && launchResume.isEmpty && launchOptimizedFirstDraw.isEmpty
                && launchExtended.isEmpty && scrollHitchMsPerS == nil && hitchMsPerS == nil
        }
    }

    /// The wire schema version (``schemaVersion``).
    public var schema: Int = HangReport.schemaVersion
    /// A random id per report: the server stores a retried report once.
    public var reportId: String
    /// ``InstallIdentity``'s random id (replaced every 30 days).
    public var installId: String
    /// The UTC day the report was built (`yyyy-MM-dd`).
    public var day: String
    /// The app that wrote the report.
    public var app: App
    /// The macOS version.
    public var os: OS
    /// The kind of Mac.
    public var hardware: HardwareClass
    /// Rounded counts of what was open.
    public var counts: CoarseCounts
    /// MetricKit hangs and the watchdog's hangs and stalls, longest first; in schema 3, the
    /// detector's blocking samples (no duration) come before them, so the body cap
    /// (``HangReportService``'s `fitted`, which drops from the end) takes the shortest stall first.
    public var hangs: [HangSample] = []
    /// MetricKit CPU exceptions, heaviest first.
    public var cpuExceptions: [CPUExceptionSample] = []
    /// The watchdog's finished stalls by duration (``StallAggregate/bucketEdgesMs``).
    public var stallHistogram: [HistogramBucket] = []
    /// MetricKit's aggregated metrics.
    public var metrics = Metrics()
    /// Allowlisted signpost interval histograms, then (schema 3) the main-turn and input-queueing
    /// histograms in category ``mainThreadCategory``.
    public var intervals: [IntervalHistogram] = []
    /// Seconds a person used cmux since the last report, from the app's activation notices and input
    /// (``ActiveTimeLedger``, Chrome's rule): the denominator of the hang and turn counts. Schema 3 only; nil, and
    /// so absent from the JSON, in schema 2, in an older report and when the app passed none.
    public var activeSeconds: Int?
    /// The launches since the last report (`launchFirstFrame`, `launchStartupComplete`,
    /// `launchLiveContent` by temperature, and `completionReasons`); schema 3 only. Nil, and so
    /// absent from the JSON, in schema 2 and when no launch was recorded.
    public var launches: LaunchAggregate?
    /// The upper edges of the ``inputLatency`` buckets, in milliseconds; schema 3 only. The three
    /// input fields are present together, or absent when the report carries no input latency.
    public var inputLatencyBucketEdgesMs: [Double]?
    /// Input latency since the last report, per kind, target, entrypoint, presentation source and
    /// display; schema 3 only.
    public var inputLatency: [InputLatencyRow]?
    /// Chrome's scroll jank counts since the last report; schema 3 only.
    public var scrollJank: ScrollJank?
    /// The person's interactions since the last report (cmux's INP); schema 3 only, absent with none.
    public var interactionLatency: InteractionLatency?
    /// This launch's catalog histograms since the last report (at most ``maxFieldHistograms``); schema 3 only.
    public var histograms: [FieldHistogram]?
    /// This launch's stability counts since the last report; schema 3 only.
    public var stability: Stability?
    /// The merged black box of the app, daemon and host rings at a hang of 1 s or more or a key frame over
    /// 50 ms, oldest first (at most ``TraceBlackBoxUpload/maxEvents``); schema 3 only, and dropped first when
    /// the body is too large.
    public var blackbox: [BlackBoxEvent]?
    /// Earlier launches' histograms and stability counts, each under its own profile; schema 3 only.
    public var launchSections: [LaunchSection]?
    /// The hash of every feature's value this launch (``FeatureState/hash``): the features arm the field
    /// import groups by. Schema 3 only; nil, and so absent from the JSON, in schema 2, in an older report and
    /// when the app passed none.
    public var featuresHash: String?
    /// The features an override decided this launch, sorted by name (at most ``maxFeatures``); present
    /// with ``featuresHash``.
    public var features: [FeatureEntry]?
    /// The main thread's blocking call sites since the last report, most calls first (at most
    /// ``maxBlockingSites``), each by its hashed site id only (``BlockingSiteCount``). Schema 3 only; nil, and so
    /// absent from the JSON, in schema 2, in an older report and when the detector is not in the build.
    public var blockingSites: [BlockingSiteCount]?

    /// Makes the value from its parts.
    public init(reportId: String, installId: String, day: String, app: App, os: OS, hardware: HardwareClass,
                counts: CoarseCounts) {
        self.reportId = reportId
        self.installId = installId
        self.day = day
        self.app = app
        self.os = os
        self.hardware = hardware
        self.counts = counts
    }

    /// Whether the report says nothing about performance (no hang, stall, metric, interval, launch,
    /// input latency or active second: active time without a hang is the rate's denominator).
    public var hasNoFindings: Bool {
        hangs.isEmpty && cpuExceptions.isEmpty && stallHistogram.allSatisfy { $0.count == 0 } && metrics.isEmpty
            && intervals.isEmpty && (launches?.isEmpty ?? true) && !hasInputLatency && (activeSeconds ?? 0) == 0
            && !hasFieldData && (blockingSites ?? []).isEmpty
    }

    /// Whether the report carries histograms, stability counts or a launch section (a black box alone is
    /// context, not a finding).
    public var hasFieldData: Bool {
        !(histograms ?? []).isEmpty || !(stability?.isEmpty ?? true) || !(launchSections ?? []).isEmpty
    }

    /// Whether the report carries input latency rows, scroll jank counts or interactions.
    public var hasInputLatency: Bool {
        !(inputLatency ?? []).isEmpty || !(scrollJank?.isEmpty ?? true) || interactionLatency != nil
    }

    /// The wire names: camelCase for the schema 2 fields and `launches`; the input latency fields
    /// use the snake_case names `debug.input` and the trace tools share (p04-input.md, DC12), and
    /// `active_seconds` follows them.
    private enum CodingKeys: String, CodingKey {
        case schema, reportId, installId, day, app, os, hardware, counts, hangs, cpuExceptions, stallHistogram
        case metrics, intervals, launches
        case inputLatencyBucketEdgesMs = "input_latency_bucket_edges_ms"
        case inputLatency = "input_latency"
        case scrollJank = "scroll_jank"
        case interactionLatency = "interaction_latency"
        case activeSeconds = "active_seconds"
        case histograms, stability, blackbox
        case launchSections = "launch_sections"
        case featuresHash = "features_hash"
        case features
        case blockingSites = "blocking_sites"
    }

    /// The wire encoder: sorted keys, so the same report always has the same bytes.
    public static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    /// The encoder of the copy the person reads (View Hang Report): the same keys, indented.
    public static var readableEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        return encoder
    }
}
