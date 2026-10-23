public import Foundation
import os

/// Runs opt-in hang reports: follows the setting, turns a trigger (a MetricKit delivery, the
/// launch) into at most one report, checks it, keeps its readable copy, and sends it through the
/// outbox. No timers: nothing here runs unless a trigger arrives.
///
/// ```swift
/// let service = HangReportService(store: HangReportStore(directory: folder), transport: URLSessionHangReportTransport(),
///                                 builder: builder, scanner: scanner, identity: InstallIdentity(),
///                                 collector: collector, environment: environment)
/// await service.setEnabled(settings.hangReports)
/// await service.launched()
/// ```
public actor HangReportService {
    /// The values a report's envelope needs from the app.
    public struct Environment: Sendable {
        public var app: HangReport.App
        public var os: HangReport.OS
        public var hardware: HardwareClass
        /// The coarse counts of what is open now (the app reads them on the main actor).
        public var counts: @Sendable () async -> CoarseCounts
        public var now: @Sendable () -> Date
        public var makeReportID: @Sendable () -> String

        public init(app: HangReport.App, os: HangReport.OS, hardware: HardwareClass,
                    counts: @escaping @Sendable () async -> CoarseCounts, now: @escaping @Sendable () -> Date = Date.init,
                    makeReportID: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() }) {
            self.app = app
            self.os = os
            self.hardware = hardware
            self.counts = counts
            self.now = now
            self.makeReportID = makeReportID
        }
    }

    /// The most reports built per UTC day.
    public static let dailyLimit = 4
    /// A launch sends a watchdog-only report when the last one is older than this.
    public static let watchdogReportInterval: TimeInterval = 24 * 60 * 60

    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "hang-reports")
    private let store: HangReportStore
    private let transport: any HangReportTransport
    private let builder: HangReportBuilder
    private let scanner: PrivacyLeakScanner
    private let identity: InstallIdentity
    private let environment: Environment
    public nonisolated let collector: HangReportCollector

    public private(set) var isEnabled = false
    /// MetricKit deliveries not yet in a report (the daily cap was reached).
    private var waiting: [MetricKitInput] = []
    /// Reports the leak scan refused (a bug if ever above 0; logged, never sent).
    public private(set) var refusedCount = 0

    public init(store: HangReportStore, transport: any HangReportTransport, builder: HangReportBuilder,
                scanner: PrivacyLeakScanner, identity: InstallIdentity, collector: HangReportCollector,
                environment: Environment) {
        self.store = store
        self.transport = transport
        self.builder = builder
        self.scanner = scanner
        self.identity = identity
        self.collector = collector
        self.environment = environment
    }

    /// The readable copy of the last report sent.
    public nonisolated var lastReportURL: URL { store.lastReportURL }

    /// Follows `diagnostics.hangReports`. Off drops what was recorded and queued and forgets the
    /// install id; the last report's readable copy stays for View Hang Report.
    public func setEnabled(_ on: Bool) async {
        guard on != isEnabled else { return }
        isEnabled = on
        collector.setEnabled(on)
        if on {
            if let saved = await store.takePending() { collector.merge(saved) }
        } else {
            waiting = []
            await store.clearQueued()
            identity.forget()
        }
    }

    /// The launch: retries the outbox, and sends a watchdog-only report when the last report is
    /// over a day old.
    public func launched() async {
        guard isEnabled else { return }
        await flushOutbox()
        let last = await store.sendLog().lastSentAt ?? .distantPast
        if environment.now().timeIntervalSince(last) >= Self.watchdogReportInterval, !collector.snapshot().isEmpty {
            await sendReport()
        }
    }

    /// A MetricKit delivery (metrics about daily, diagnostics usually at the next launch).
    public func receive(_ input: MetricKitInput) async {
        guard isEnabled, !input.isEmpty else { return }
        waiting.append(input)
        if waiting.count > 8 { waiting.removeFirst(waiting.count - 8) }
        await sendReport()
    }

    /// Saves the watchdog's findings for the next launch (call when the app quits). Synchronous on
    /// purpose: `applicationWillTerminate` cannot wait for the actor; it writes one small file the
    /// actor only reads at the next launch's `setEnabled(true)`.
    public nonisolated func saveForNextLaunch() {
        let aggregate = collector.snapshot()
        guard collector.isEnabled, !aggregate.isEmpty, let data = try? JSONEncoder().encode(aggregate) else { return }
        let url = store.directory.appending(path: "pending.json")
        try? FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    /// What View Hang Report opens: the last report sent, else a preview of what would be sent now.
    public func viewableReport() async -> URL? {
        if await store.hasLastReport() { return store.lastReportURL }
        // While off, the preview names a throwaway id: viewing must not start an install id.
        let report = await build(watchdog: collector.snapshot(), metricKit: waiting,
                                 installId: isEnabled ? nil : UUID().uuidString.lowercased())
        guard let readable = try? HangReport.readableEncoder.encode(report),
              scanner.findings(in: readable).isEmpty else { return nil }
        await store.savePreview(readable)
        return store.previewURL
    }

    // MARK: Sending

    private func sendReport() async {
        let now = environment.now()
        let today = Self.day(now)
        var log = await store.sendLog()
        if log.day != today { log = HangReportStore.SendLog() }
        guard log.sentToday < Self.dailyLimit else { return }
        let aggregate = collector.drain()
        let report = Self.fitted(await build(watchdog: aggregate, metricKit: waiting))
        waiting = []
        guard !report.hasNoFindings, let body = try? HangReport.encoder.encode(report),
              body.count <= HangReport.maxBodyBytes else { return }
        let findings = scanner.findings(in: body)
        guard findings.isEmpty else {
            refusedCount += 1
            logger.error("hang report refused by the leak scan: \(findings.count) findings, first \(findings[0].description, privacy: .public)")
            return
        }
        if let readable = try? HangReport.readableEncoder.encode(report) { await store.saveLastReport(readable) }
        await store.enqueue(body, reportId: report.reportId)
        log.day = today
        log.sentToday += 1
        log.lastSentAt = now
        await store.saveSendLog(log)
        await flushOutbox()
    }

    private func flushOutbox() async {
        for entry in await store.outbox(now: environment.now()) {
            switch await transport.send(entry.body) {
            case .accepted, .refused:
                await store.remove(entry.url)
            case .retryLater:
                return
            }
        }
    }

    private func build(watchdog: StallAggregate, metricKit: [MetricKitInput], installId: String? = nil) async -> HangReport {
        let now = environment.now()
        let context = HangReportBuilder.Context(
            reportId: environment.makeReportID(), installId: installId ?? identity.current(), day: Self.day(now), app: environment.app,
            os: environment.os, hardware: environment.hardware, counts: await environment.counts())
        return builder.build(context: context, watchdog: watchdog, metricKit: metricKit)
    }

    /// `report` shrunk until it encodes under the body cap: the shortest hangs, then CPU
    /// exceptions, then intervals go first.
    static func fitted(_ report: HangReport) -> HangReport {
        var report = report
        while (try? HangReport.encoder.encode(report).count) ?? 0 > HangReport.maxBodyBytes {
            if !report.hangs.isEmpty { report.hangs.removeLast() } else if !report.cpuExceptions.isEmpty {
                report.cpuExceptions.removeLast()
            } else if !report.intervals.isEmpty { report.intervals.removeLast() } else { break }
        }
        return report
    }

    /// The UTC day of `date` (`yyyy-MM-dd`).
    static func day(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04ld-%02ld-%02ld", parts.year ?? 1970, parts.month ?? 1, parts.day ?? 1)
    }
}
