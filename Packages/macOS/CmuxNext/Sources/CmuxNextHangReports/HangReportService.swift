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
        /// The app that wrote the report.
        public var app: HangReport.App
        /// The macOS version.
        public var os: HangReport.OS
        /// The kind of Mac.
        public var hardware: HardwareClass
        /// The coarse counts of what is open now (the app reads them on the main actor).
        public var counts: @Sendable () async -> CoarseCounts
        /// The clock (tests pass a fixed one).
        public var now: @Sendable () -> Date
        /// Makes each report's random id.
        public var makeReportID: @Sendable () -> String
        /// Whether sending is still allowed, read before each report, delivery and send (the app
        /// passes the managed `DisableTelemetry`, so a profile installed while cmux runs stops the
        /// next send and drops what was recorded).
        public var stillAllowed: @Sendable () -> Bool

        /// Makes the value from its parts.
        public init(app: HangReport.App, os: HangReport.OS, hardware: HardwareClass,
                    counts: @escaping @Sendable () async -> CoarseCounts, now: @escaping @Sendable () -> Date = Date.init,
                    makeReportID: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() },
                    stillAllowed: @escaping @Sendable () -> Bool = { true }) {
            self.app = app
            self.os = os
            self.hardware = hardware
            self.counts = counts
            self.now = now
            self.makeReportID = makeReportID
            self.stillAllowed = stillAllowed
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
    /// The watchdog sink that feeds each report.
    public nonisolated let collector: HangReportCollector

    /// Whether hang reports are on.
    public private(set) var isEnabled = false
    /// The first ``setEnabled(_:)`` always runs, so a setting turned off while cmux was closed
    /// still clears what an earlier launch left on disk.
    private var settled = false
    /// Changes at every ``setEnabled(_:)``: work that suspended checks it before it writes or
    /// sends, so nothing goes out after the person turned reports off (actor reentrancy).
    private var generation = 0
    /// One send or flush at a time; a trigger that arrives meanwhile asks for another pass.
    private var isSending = false
    private var sendAgain = false
    private var isFlushing = false
    private var flushAgain = false
    /// MetricKit deliveries not yet in a report (the daily cap was reached).
    private var waiting: [MetricKitInput] = []
    /// Reports the leak scan refused (a bug if ever above 0; logged, never sent).
    public private(set) var refusedCount = 0

    /// Makes the value from its parts.
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
        guard !settled || on != isEnabled else { return }
        settled = true
        isEnabled = on
        generation += 1
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
        guard isEnabled, await allowed() else { return }
        await flushOutbox()
        let last = await store.sendLog().lastSentAt ?? .distantPast
        if environment.now().timeIntervalSince(last) >= Self.watchdogReportInterval, !collector.snapshot().isEmpty {
            await sendReport()
        }
    }

    /// A MetricKit delivery (metrics about daily, diagnostics usually at the next launch).
    public func receive(_ input: MetricKitInput) async {
        guard isEnabled, !input.isEmpty, await allowed() else { return }
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

    /// Builds and queues one report from what was recorded, then flushes the outbox. Takes its
    /// inputs and its daily slot before the first suspension, and stops when reports were turned
    /// off while it waited.
    private func sendReport() async {
        guard !isSending else { sendAgain = true; return }
        isSending = true
        defer { isSending = false }
        // At most one more pass per trigger that arrived during a send (each pass drains the inputs).
        for _ in 0..<2 {
            sendAgain = false
            await sendOnce()
            guard sendAgain, isEnabled else { break }
        }
    }

    private func sendOnce() async {
        guard await allowed() else { return }
        let started = generation
        let now = environment.now()
        let today = Self.day(now)
        var log = await store.sendLog()
        guard generation == started else { return }
        if log.day != today { log = HangReportStore.SendLog() }
        guard log.sentToday < Self.dailyLimit else { return }
        let aggregate = collector.drain()
        let deliveries = waiting
        waiting = []
        guard !aggregate.isEmpty || !deliveries.isEmpty else { return }
        log.day = today
        log.sentToday += 1
        log.lastSentAt = now
        await store.saveSendLog(log)
        let report = Self.fitted(await build(watchdog: aggregate, metricKit: deliveries))
        guard generation == started, !report.hasNoFindings, let body = try? HangReport.encoder.encode(report),
              body.count <= HangReport.maxBodyBytes else { return }
        let findings = scanner.findings(in: body)
        guard findings.isEmpty else {
            refusedCount += 1
            logger.error("hang report refused by the leak scan: \(findings.count) findings, first \(findings[0].description, privacy: .public)")
            return
        }
        guard generation == started else { return }
        await store.enqueue(body, reportId: report.reportId)
        // The readable copy (View Hang Report) is the queued body's, written only while reports are on.
        if generation == started, let readable = try? HangReport.readableEncoder.encode(report) { await store.saveLastReport(readable) }
        await flushOutbox()
    }

    private func flushOutbox() async {
        guard isEnabled else { return }
        guard !isFlushing else { flushAgain = true; return }
        isFlushing = true
        defer { isFlushing = false }
        // A report queued during a pass gets one more pass, not the next day's trigger.
        for _ in 0..<2 {
            flushAgain = false
            guard await flushOnce(), flushAgain else { return }
        }
    }

    /// One pass over the outbox, oldest first. False when it stopped early (off, or retry later).
    private func flushOnce() async -> Bool {
        let started = generation
        for entry in await store.outbox(now: environment.now()) {
            guard generation == started, await allowed() else { return false }
            // The outbox outlives an update: a report another build queued (under older rules) or
            // one the leak scan refuses now is dropped, never sent.
            guard isSendable(entry.body) else {
                await store.remove(entry.url)
                continue
            }
            switch await transport.send(entry.body) {
            case .accepted, .refused:
                await store.remove(entry.url)
            case .retryLater:
                return false
            }
        }
        return true
    }

    /// Whether a queued body would be sent: built by this build (its schema and app), and clean.
    private func isSendable(_ body: Data) -> Bool {
        guard let report = try? JSONDecoder().decode(HangReport.self, from: body), report.schema == HangReport.schemaVersion,
              report.app == HangReportBuilder.safeApp(environment.app) else { return false }
        return scanner.findings(in: body).isEmpty
    }

    /// ``Environment/stillAllowed``; when it says no, everything recorded and queued is dropped
    /// (off), so nothing recorded while sending was not allowed goes out later.
    private func allowed() async -> Bool {
        guard environment.stillAllowed() else {
            if isEnabled { await setEnabled(false) }
            return false
        }
        return true
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
