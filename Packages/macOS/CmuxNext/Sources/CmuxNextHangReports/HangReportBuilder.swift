public import Foundation

/// Builds a ``HangReport`` by allow-list: it copies only the fields of hang-reports-DESIGN.md
/// section 4 from typed inputs, and every frame goes through ``ImageClassifier``.
///
/// ```swift
/// let builder = HangReportBuilder(classifier: classifier, resolver: DyldImageResolver())
/// let report = builder.build(context: context, watchdog: aggregate, metricKit: deliveries)
/// ```
public nonisolated struct HangReportBuilder: Sendable {
    /// The envelope of one report: who, when and what was open.
    public struct Context: Sendable, Equatable {
        /// A random id per report.
        public var reportId: String
        /// ``InstallIdentity``'s id.
        public var installId: String
        /// The UTC day (`yyyy-MM-dd`).
        public var day: String
        /// The app that wrote the report.
        public var app: HangReport.App
        /// The macOS version.
        public var os: HangReport.OS
        /// The kind of Mac.
        public var hardware: HardwareClass
        /// Rounded counts of what was open.
        public var counts: CoarseCounts

        /// Makes the value from its parts.
        public init(reportId: String, installId: String, day: String, app: HangReport.App, os: HangReport.OS,
                    hardware: HardwareClass, counts: CoarseCounts) {
            self.reportId = reportId
            self.installId = installId
            self.day = day
            self.app = app
            self.os = os
            self.hardware = hardware
            self.counts = counts
        }
    }

    /// Decides what each frame may say.
    public let classifier: ImageClassifier
    /// Finds the loaded image of an address or UUID.
    public let resolver: any ImageResolving
    private let reader = CallStackTreeReader()

    /// Makes the value from its parts.
    public init(classifier: ImageClassifier, resolver: any ImageResolving) {
        self.classifier = classifier
        self.resolver = resolver
    }

    /// The report of `watchdog`'s findings and the MetricKit deliveries since the last report.
    public func build(context: Context, watchdog: StallAggregate, metricKit: [MetricKitInput]) -> HangReport {
        var report = HangReport(reportId: context.reportId, installId: context.installId, day: Self.safeDay(context.day),
                                app: Self.safeApp(context.app), os: HangReport.OS(version: Self.safeVersion(context.os.version)),
                                hardware: context.hardware, counts: context.counts)
        let metricKitHangs = metricKit.flatMap(\.hangs).map { hang in
            HangSample(source: .metrickit, kind: .hang, durationMs: hang.durationMs, frames: frames(hang.callStackTree))
        }
        report.hangs = Array((metricKitHangs + watchdog.hangs + watchdog.stalls).sorted { $0.durationMs > $1.durationMs }
            .prefix(HangReport.maxHangs))
        report.cpuExceptions = Array(metricKit.flatMap(\.cpuExceptions).sorted { $0.cpuMs > $1.cpuMs }
            .prefix(HangReport.maxCPUExceptions)
            .map { CPUExceptionSample(cpuMs: $0.cpuMs, sampledMs: $0.sampledMs, frames: frames($0.callStackTree)) })
        report.stallHistogram = watchdog.histogram
        report.metrics = Self.metrics(metricKit.map(\.metrics))
        report.intervals = Self.intervals(metricKit.flatMap(\.signposts))
        return report
    }

    /// Frames of a watchdog sample (return addresses, innermost first).
    public func frames(addresses: [UInt]) -> [HangReportFrame] {
        addresses.prefix(HangSample.maxFrames).map { address in
            classifier.frame(image: resolver.image(containing: UInt64(address)), address: UInt64(address))
        }
    }

    /// Frames of a MetricKit call stack tree.
    func frames(_ callStackTree: Data) -> [HangReportFrame] {
        var loaded: [String: LoadedImage?] = [:]
        return reader.stack(callStackTree).map { raw in
            let uuid = raw.binaryUUID?.uppercased()
            let image = uuid.flatMap { uuid -> LoadedImage? in
                if let known = loaded[uuid] { return known }
                let found = resolver.image(uuid: uuid)
                loaded[uuid] = found
                return found
            }
            return classifier.frame(metricKitName: raw.binaryName, uuid: uuid, offset: raw.offset, loaded: image)
        }
    }

    /// The deliveries' metrics, merged: histograms add, ratios keep the newest.
    static func metrics(_ all: [HangReport.Metrics]) -> HangReport.Metrics {
        var merged = HangReport.Metrics()
        merged.hangTime = HistogramBucket.normalized(all.flatMap(\.hangTime))
        merged.launchFirstDraw = HistogramBucket.normalized(all.flatMap(\.launchFirstDraw))
        merged.launchResume = HistogramBucket.normalized(all.flatMap(\.launchResume))
        merged.launchOptimizedFirstDraw = HistogramBucket.normalized(all.flatMap(\.launchOptimizedFirstDraw))
        merged.launchExtended = HistogramBucket.normalized(all.flatMap(\.launchExtended))
        merged.scrollHitchMsPerS = all.compactMap(\.scrollHitchMsPerS).last.flatMap(safeRatio)
        merged.hitchMsPerS = all.compactMap(\.hitchMsPerS).last.flatMap(safeRatio)
        return merged
    }

    /// Allowlisted intervals only (``HangReportSignposts/allows(category:name:)``), merged by
    /// category and name.
    static func intervals(_ signposts: [MetricKitInput.Signpost]) -> [IntervalHistogram] {
        var merged: [String: IntervalHistogram] = [:]
        var order: [String] = []
        for signpost in signposts where HangReportSignposts.allows(category: signpost.category, name: signpost.name) {
            let key = signpost.category + " " + signpost.name
            if var existing = merged[key] {
                existing.count += max(0, signpost.count)
                existing.buckets = HistogramBucket.normalized(existing.buckets + signpost.buckets)
                existing.hitchMsPerS = signpost.hitchMsPerS.flatMap(safeRatio) ?? existing.hitchMsPerS
                merged[key] = existing
            } else {
                merged[key] = IntervalHistogram(category: signpost.category, name: signpost.name, count: signpost.count,
                                                buckets: signpost.buckets, hitchMsPerS: signpost.hitchMsPerS.flatMap(safeRatio))
                order.append(key)
            }
        }
        return Array(order.compactMap { merged[$0] }.prefix(HangReport.maxIntervals))
    }

    /// A ratio in 0...1000 ms per s, else nil.
    static func safeRatio(_ value: Double) -> Double? {
        value.isFinite && value >= 0 && value <= 1_000 ? value : nil
    }

    /// `yyyy-MM-dd`, else `1970-01-01`.
    static func safeDay(_ day: String) -> String {
        day.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}$"#, options: .regularExpression) != nil ? day : "1970-01-01"
    }

    /// Digits and dots (at most 4 parts of at most 6 digits), else `0`.
    static func safeVersion(_ version: String) -> String {
        version.range(of: #"^[0-9]{1,6}(\.[0-9]{1,6}){0,3}$"#, options: .regularExpression) != nil ? version : "0"
    }

    /// A build number: a version, or one run of up to 20 digits (NIGHTLY's `CFBundleVersion` is the
    /// CI run id plus the attempt, about 13 digits); else `0`.
    static func safeBuild(_ build: String) -> String {
        build.range(of: #"^[0-9]{1,20}$"#, options: .regularExpression) != nil ? build : safeVersion(build)
    }

    static func safeApp(_ app: HangReport.App) -> HangReport.App {
        let channels = ["nightly", "dev", "rc", "release"]
        return HangReport.App(version: safeVersion(app.version), build: safeBuild(app.build),
                              channel: channels.contains(app.channel) ? app.channel : "dev")
    }
}
