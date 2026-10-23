public import Foundation

/// One opt-in hang report, wire schema 1 (plans/cmux-next/hang-reports-DESIGN.md section 4).
///
/// Every field is a closed set: enums, bucket labels, version numbers, durations, counts and
/// ``HangFrame`` values whose names passed ``ImageClassifier``. ``HangReportBuilder`` is the only
/// producer; ``PrivacyLeakScanner`` checks the encoded bytes before anything leaves the Mac.
///
/// ```swift
/// let report = builder.build(context: context, watchdog: collector.drain(), metricKit: inputs)
/// let body = try HangReport.encoder.encode(report)
/// ```
public nonisolated struct HangReport: Codable, Sendable, Equatable {
    /// The wire schema this type writes.
    public static let schemaVersion = 1
    /// The most hangs and stalls one report carries.
    public static let maxHangs = 20
    /// The most CPU exceptions one report carries.
    public static let maxCPUExceptions = 5
    /// The most signpost intervals one report carries.
    public static let maxIntervals = 64
    /// The largest body the server accepts (64 KiB).
    public static let maxBodyBytes = 64 * 1024

    /// The app that wrote the report.
    public struct App: Codable, Sendable, Equatable {
        /// `CFBundleShortVersionString` (digits and dots).
        public var version: String
        /// `CFBundleVersion` (digits and dots).
        public var build: String
        /// `nightly`, `dev`, `rc` or `release`.
        public var channel: String

        public init(version: String, build: String, channel: String) {
            self.version = version
            self.build = build
            self.channel = channel
        }
    }

    /// The operating system, as `major.minor.patch` only.
    public struct OS: Codable, Sendable, Equatable {
        public var version: String

        public init(version: String) {
            self.version = version
        }
    }

    /// MetricKit's aggregated histograms and ratios (all optional: a report without a metric
    /// payload carries none).
    public struct Metrics: Codable, Sendable, Equatable {
        public var hangTime: [HistogramBucket] = []
        public var launchFirstDraw: [HistogramBucket] = []
        public var launchResume: [HistogramBucket] = []
        public var launchOptimizedFirstDraw: [HistogramBucket] = []
        public var launchExtended: [HistogramBucket] = []
        /// `MXAnimationMetric.scrollHitchTimeRatio`, milliseconds of hitch per second of scrolling.
        public var scrollHitchMsPerS: Double?
        /// `MXAnimationMetric.hitchTimeRatio` (macOS 26), milliseconds of hitch per second.
        public var hitchMsPerS: Double?

        public init() {}

        /// Whether no metric arrived.
        public var isEmpty: Bool {
            hangTime.isEmpty && launchFirstDraw.isEmpty && launchResume.isEmpty && launchOptimizedFirstDraw.isEmpty
                && launchExtended.isEmpty && scrollHitchMsPerS == nil && hitchMsPerS == nil
        }
    }

    public var schema: Int = HangReport.schemaVersion
    /// A random id per report: the server stores a retried report once.
    public var reportId: String
    /// ``InstallIdentity``'s random id (replaced every 30 days).
    public var installId: String
    /// The UTC day the report was built (`yyyy-MM-dd`).
    public var day: String
    public var app: App
    public var os: OS
    public var hardware: HardwareClass
    public var counts: CoarseCounts
    /// MetricKit hangs and the watchdog's hangs and stalls, longest first.
    public var hangs: [HangSample] = []
    public var cpuExceptions: [CPUExceptionSample] = []
    /// The watchdog's finished stalls by duration (``StallAggregate/bucketEdgesMs``).
    public var stallHistogram: [HistogramBucket] = []
    public var metrics = Metrics()
    public var intervals: [IntervalHistogram] = []

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

    /// Whether the report says nothing about performance (no hang, stall, metric or interval).
    public var hasNoFindings: Bool {
        hangs.isEmpty && cpuExceptions.isEmpty && stallHistogram.allSatisfy { $0.count == 0 } && metrics.isEmpty
            && intervals.isEmpty
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
