import CryptoKit
public import CmuxNextMetrics
public import CmuxNextTrace
import Foundation

/// Schema 3's field data (``HangReport/histograms``, ``HangReport/stability``, ``HangReport/blackbox``,
/// ``HangReport/launchSections``), by allow-list: catalog names, closed-set labels and
/// numbers only.
extension HangReportBuilder {
    /// What a report's field data is made from.
    public struct FieldDataInput: Sendable, Equatable {
        /// This launch's samples since the last queued report (``MetricsStore/delta()``).
        public var current: MetricsDelta?
        /// Earlier launches' unsent samples, each under its own profile (task 053's fold), oldest first.
        public var sections: [MetricsLaunchContents]
        /// The merged rings' records taken at the last trigger (``HangReportCollector/takeBlackBox()``).
        public var blackbox: [TraceBlackBoxUpload.Record]

        /// Makes the value from its parts.
        public init(current: MetricsDelta? = nil, sections: [MetricsLaunchContents] = [],
                    blackbox: [TraceBlackBoxUpload.Record] = []) {
            self.current = current
            self.sections = sections
            self.blackbox = blackbox
        }
    }

    /// Adds `input` to `report`: the histograms and stability counts of this launch, the first
    /// ``HangReport/maxLaunchSections`` non-empty sections, and the black box.
    static func addFieldData(_ input: FieldDataInput, to report: inout HangReport) {
        if let current = input.current {
            let (histograms, stability) = fieldData(current)
            report.histograms = histograms.isEmpty ? nil : histograms
            report.stability = stability.isEmpty ? nil : stability
        }
        let sections = input.sections.lazy.compactMap(launchSection).prefix(HangReport.maxLaunchSections)
        report.launchSections = sections.isEmpty ? nil : Array(sections)
        let events = blackboxEvents(input.blackbox)
        report.blackbox = events.isEmpty ? nil : events
    }

    /// The histograms (the ``HangReport/maxFieldHistograms`` with the most samples, in directory order) and the
    /// stability counts of `delta`. A name outside this build's catalog, and Chromium's own layout, are left out.
    public static func fieldData(_ delta: MetricsDelta) -> (histograms: [HangReport.FieldHistogram], stability: HangReport.Stability) {
        var stability = HangReport.Stability()
        var candidates: [HangReport.FieldHistogram] = []
        for histogram in delta.histograms where HangReport.histogramCatalog.contains(histogram.name) {
            if isStability(histogram.name) {
                addStability(histogram, to: &stability)
            } else if let field = fieldHistogram(histogram) {
                candidates.append(field)
            }
        }
        let kept = candidates.enumerated()
            .sorted { ($0.element.count, $1.offset) > ($1.element.count, $0.offset) }
            .prefix(HangReport.maxFieldHistograms)
            .sorted { $0.offset < $1.offset }
            .map(\.element)
        return (kept, stability)
    }

    /// The part of `delta` a report with `histograms` sends: each sent histogram with its wire buckets, count and
    /// sum, and every stability histogram (``HangReport/stability`` is never cut). The service marks it logged
    /// once the report is queued, so what a report left out goes in a later one (Chrome's
    /// `HistogramSnapshotManager` marks only the logged samples).
    public static func sentDelta(_ delta: MetricsDelta, histograms: [HangReport.FieldHistogram]) -> MetricsDelta {
        let wire = Dictionary(histograms.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        var sent = delta
        sent.histograms = delta.histograms.compactMap { histogram in
            guard HangReport.histogramCatalog.contains(histogram.name) else { return nil }
            if isStability(histogram.name) { return histogram }
            guard let field = wire[histogram.name] else { return nil }
            guard field.buckets.count != histogram.buckets.count else { return histogram }
            let indices = Set(field.buckets.map(\.index))
            var part = histogram
            part.buckets = histogram.buckets.filter { indices.contains($0.index) }
            part.count = field.count
            part.sum = field.sum
            return part
        }
        return sent
    }

    /// The catalog ids by name.
    static let catalogByName: [String: HistogramID] = Dictionary(HistogramID.allCases.map { ($0.name, $0) },
                                                                 uniquingKeysWith: { first, _ in first })

    /// The histograms whose samples are ``HangReport/Stability`` counts, not `histograms[]`.
    static func isStability(_ name: String) -> Bool {
        switch catalogByName[name] {
        case .stabilityLaunch?, .stabilityActiveSeconds?, .stabilityUncleanExit?, .stabilityChildExit?, .daemonUnresponsive?: true
        default: false
        }
    }

    /// A histogram's wire form: its ``HangReport/maxFieldBuckets`` fullest buckets, by index. With more buckets
    /// than that, the count is the kept buckets' and the sum their share of it, so the rest and its sum stay
    /// for a later report. Nil for Chromium's layout.
    static func fieldHistogram(_ histogram: MetricsDelta.Histogram) -> HangReport.FieldHistogram? {
        guard let id = catalogByName[histogram.name], let unit = unitName(id.unit), let ceiling = ceiling(histogram.layout) else {
            return nil
        }
        let all = histogram.buckets.filter { $0.count > 0 }
        var kept = all
        if all.count > HangReport.maxFieldBuckets {
            kept = Array(all.sorted { ($0.count, $1.index) > ($1.count, $0.index) }.prefix(HangReport.maxFieldBuckets))
                .sorted { $0.index < $1.index }
        }
        let buckets = kept.map { HangReport.FieldHistogram.Bucket(index: $0.index, count: $0.count) }
        guard kept.count < all.count else {
            return HangReport.FieldHistogram(name: histogram.name, unit: unit, buckets: buckets, count: histogram.count,
                                             sum: histogram.sum, max: ceiling)
        }
        let keptCount = kept.reduce(UInt64(0)) { $0 &+ $1.count }
        // sum * kept / count, never above sum: kept is clamped to count.
        let sum = histogram.count == 0 ? 0
            : histogram.count.dividingFullWidth(histogram.sum.multipliedFullWidth(by: min(keptCount, histogram.count))).quotient
        return HangReport.FieldHistogram(name: histogram.name, unit: unit, buckets: buckets, count: keptCount, sum: sum, max: ceiling)
    }

    /// The wire unit of `unit`; nil for Chromium's.
    static func unitName(_ unit: HistogramID.Unit) -> String? {
        switch unit {
        case .microseconds: "us"
        case .milliseconds: "ms"
        case .kibibytes: "kib"
        case .percent: "pct"
        case .count: "count"
        case .enumeration: "enum"
        case .chromium: nil
        }
    }

    /// The layout's maximum or value count; nil for Chromium's.
    static func ceiling(_ layout: HistogramID.Layout) -> Int64? {
        switch layout {
        case let .logLinear(maximum), let .linear(maximum): maximum
        case let .enumeration(valueCount): Int64(valueCount)
        case .chromium: nil
        }
    }

    /// Adds a stability histogram's samples to `stability`; an enumeration value outside its list is left out.
    static func addStability(_ histogram: MetricsDelta.Histogram, to stability: inout HangReport.Stability) {
        func counts<Value>(_ value: (Int) -> Value?, _ name: (Value) -> String) -> [String: UInt64] {
            var counts: [String: UInt64] = [:]
            for bucket in histogram.buckets where bucket.count > 0 {
                guard let decoded = value(bucket.index) else { continue }
                counts[name(decoded), default: 0] &+= bucket.count
            }
            return counts
        }
        func add(_ new: [String: UInt64], to old: inout [String: UInt64]) {
            old.merge(new) { $0 &+ $1 }
        }
        switch catalogByName[histogram.name] {
        case .stabilityLaunch?:
            stability.launch &+= histogram.count
        case .stabilityActiveSeconds?:
            stability.activeSeconds &+= histogram.sum
        case .stabilityUncleanExit?:
            add(counts({ HistogramID.UncleanExit(rawValue: Int64($0)) }, uncleanExitName), to: &stability.uncleanExit)
        case let .stabilityChildExit(kind)?:
            let exits = counts({ HistogramID.ChildExit(rawValue: Int64($0)) }, childExitName)
            if !exits.isEmpty { add(exits, to: &stability.childExit[kind.rawValue, default: [:]]) }
        case .daemonUnresponsive?:
            let classes = HistogramID.MethodClass.allCases
            add(counts({ classes.indices.contains($0) ? classes[$0] : nil }, \.rawValue), to: &stability.daemonUnresponsive)
        default:
            break
        }
    }

    static func uncleanExitName(_ exit: HistogramID.UncleanExit) -> String {
        switch exit {
        case .crash: "crash"
        case .systemShutdown: "system_shutdown"
        case .killed: "killed"
        case .fatalHang: "fatal_hang"
        }
    }

    static func childExitName(_ exit: HistogramID.ChildExit) -> String {
        switch exit {
        case .clean: "clean"
        case .signal: "signal"
        case .panic: "panic"
        case .oom: "oom"
        }
    }

    /// An earlier launch's section, nil when it holds no catalog sample.
    public static func launchSection(_ contents: MetricsLaunchContents) -> HangReport.LaunchSection? {
        let (histograms, stability) = fieldData(contents.delta)
        guard !histograms.isEmpty || !stability.isEmpty else { return nil }
        let profile = contents.profile
        let channel = profile.channel == "stable" ? "release" : profile.channel
        let day = String(format: "%04ld-%02ld-%02ld", profile.buildDay.year, profile.buildDay.month, profile.buildDay.day)
        let app = safeApp(HangReport.App(version: profile.appVersion, build: profile.buildNumber, channel: channel))
        return HangReport.LaunchSection(
            id: sectionID(contents.id),
            profile: HangReport.LaunchSection.Profile(version: app.version, build: app.build, channel: app.channel,
                                                      os: safeVersion(profile.osVersion), buildDay: safeDay(day)),
            histograms: histograms, stability: stability.isEmpty ? nil : stability)
    }

    /// A UUID-shaped digest of a source launch's id (role, pid, start time, boot session): stable for one
    /// launch, and none of its parts can be read back.
    static func sectionID(_ launchID: String) -> String {
        let hex = SHA256.hash(data: Data(launchID.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        let parts = [0 ..< 8, 8 ..< 12, 12 ..< 16, 16 ..< 20, 20 ..< 32].map { range in
            String(hex.dropFirst(range.lowerBound).prefix(range.count))
        }
        return parts.joined(separator: "-")
    }

    /// The black box's events: the records the upload decoder keeps (no key-timing, per-key PTY or flow record,
    /// at most ``TraceBlackBoxUpload/maxEvents``, oldest first), with a known phase and a name of letters, digits,
    /// `.`, `_` and `-`.
    static func blackboxEvents(_ records: [TraceBlackBoxUpload.Record]) -> [HangReport.BlackBoxEvent] {
        let kept = TraceBlackBoxUpload().events(records)
        guard let first = kept.first?.timestamp else { return [] }
        return kept.compactMap { record in
            guard let name = record.name?.text, isEventName(name),
                  let phase = TraceRecord.Phase(rawValue: record.phaseCode) else { return nil }
            return HangReport.BlackBoxEvent(tUs: (record.timestamp &- first) / 1_000, process: HangReport.blackBoxProcess(record.process),
                                            name: name, phase: String(Character(Unicode.Scalar(phase.rawValue))),
                                            arg0: record.arg0 == 0 ? nil : record.arg0, arg1: record.arg1 == 0 ? nil : record.arg1)
        }
    }

    static func isEventName(_ name: String) -> Bool {
        (1 ... 64).contains(name.utf8.count) && name.utf8.allSatisfy { byte in
            (0x30 ... 0x39).contains(byte) || (0x41 ... 0x5A).contains(byte) || (0x61 ... 0x7A).contains(byte)
                || byte == 0x2E || byte == 0x5F || byte == 0x2D
        }
    }
}
