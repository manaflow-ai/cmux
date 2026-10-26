import CmuxNextInputCore
import CmuxNextMetrics
import CmuxNextTrace
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
        /// The input latency field report (``HangReportInputLatencySource``); nil (the default)
        /// until the app wires it (p04-input-104). Used only when the builder's wire schema
        /// carries input latency.
        public var inputLatency: (any HangReportInputLatencySource)?
        /// The active time and the main-turn and input-queueing histograms
        /// (``MainThreadReportLedger``, fed by ``MainThreadActivityFeed``); nil (the default) where the
        /// app has none. Used only when the builder's wire schema carries them.
        public var mainThread: MainThreadReportLedger?
        /// The metrics store, earlier launches and black-box rings (``HangReportFieldSources``); nil (the
        /// default) where the app has none. Used only when the builder's wire schema carries field data.
        public var fieldData: HangReportFieldSources?

        /// Makes the value from its parts.
        public init(app: HangReport.App, os: HangReport.OS, hardware: HardwareClass,
                    counts: @escaping @Sendable () async -> CoarseCounts, now: @escaping @Sendable () -> Date = Date.init,
                    makeReportID: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() },
                    stillAllowed: @escaping @Sendable () -> Bool = { true },
                    inputLatency: (any HangReportInputLatencySource)? = nil, mainThread: MainThreadReportLedger? = nil,
                    fieldData: HangReportFieldSources? = nil) {
            self.app = app
            self.os = os
            self.hardware = hardware
            self.counts = counts
            self.now = now
            self.makeReportID = makeReportID
            self.stillAllowed = stillAllowed
            self.inputLatency = inputLatency
            self.mainThread = mainThread
            self.fieldData = fieldData
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

    /// Follows `diagnostics.hangReports`. Off drops what was recorded and queued (the input
    /// latency field report and the main-thread part too) and forgets the install id; the last
    /// report's readable copy stays for View Hang Report. On or off, active time and turns from
    /// before now are never sent.
    public func setEnabled(_ on: Bool) async {
        guard !settled || on != isEnabled else { return }
        // Turned on while cmux runs: the samples recorded while off are never sent.
        let turnedOnNow = settled && on
        settled = true
        isEnabled = on
        generation += 1
        let started = generation
        collector.setEnabled(on)
        mainThreadLedger?.restart()
        await syncInputLatencyRecording()
        if on {
            if turnedOnNow { fieldSources?.discardCurrent() }
            if let saved = await store.takePending() { collector.merge(saved) }
            if let saved = await store.takePendingMainThread(), generation == started { mainThreadLedger?.merge(saved) }
        } else {
            waiting = []
            fieldSources?.discardCurrent()
            await fieldSources?.discardEarlierLaunches()
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
        // An earlier launch's samples (a crashed one's above all) go at launch, under the daily cap.
        if await fieldSources?.earlierLaunches().isEmpty == false {
            await sendReport()
            return
        }
        guard environment.now().timeIntervalSince(last) >= Self.watchdogReportInterval else { return }
        let samples = await fieldSources?.currentDelta() != nil
        if samples || hasSendable(collector.snapshot()) || mainThreadLedger?.take().isEmpty == false {
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

    /// Saves the watchdog's findings and the main-thread part not yet sent for the next launch
    /// (call when the app quits). Synchronous on purpose: `applicationWillTerminate` cannot wait for
    /// the actor; it writes small files the actor only reads at the next launch's `setEnabled(true)`.
    public nonisolated func saveForNextLaunch() {
        guard collector.isEnabled else {
            // Off: what this launch recorded is marked sent, so the next launch's fold sends none of it.
            fieldSources?.discardCurrent()
            return
        }
        let aggregate = collector.snapshot()
        if !aggregate.isEmpty, let data = try? JSONEncoder().encode(aggregate) {
            write(data, to: store.directory.appending(path: "pending.json"))
        }
        if let saved = mainThreadLedger?.saved(), !saved.isEmpty, let data = try? JSONEncoder().encode(saved) {
            write(data, to: store.pendingMainThreadURL)
        }
    }

    private nonisolated func write(_ data: Data, to url: URL) {
        try? FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    /// What View Hang Report opens: the last report sent, else a preview of what would be sent now.
    public func viewableReport() async -> URL? {
        if await store.hasLastReport() { return store.lastReportURL }
        // While off, the preview names a throwaway id: viewing must not start an install id. The
        // input latency is the field report's preview, so the preview holds the keys a send adds.
        var inputLatency: InputLatencySnapshot?
        if isEnabled, let source = inputLatencySource { inputLatency = await source.preview() }
        let mainThread = isEnabled ? mainThreadLedger?.take().input : nil
        let fieldData = isEnabled ? await fieldDataInput(blackbox: collector.blackBoxSnapshot()).input : nil
        let report = Self.fitted(await build(watchdog: collector.snapshot(), metricKit: waiting, inputLatency: inputLatency,
                                             mainThread: mainThread, fieldData: fieldData,
                                             installId: isEnabled ? nil : UUID().uuidString.lowercased()))
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
        // Read, not taken: the ledger moves on only once the report is queued (commit below), and a
        // report with no hang still carries the active time, so the rate's denominator is complete.
        let mainThread = mainThreadLedger?.take()
        // Read, not taken, as the ledger: the samples and sections are marked sent once the report is queued.
        let field = await fieldDataInput(blackbox: collector.takeBlackBox())
        guard generation == started else { return }
        guard hasSendable(aggregate) || !deliveries.isEmpty || mainThread?.isEmpty == false || field.hasContent else { return }
        log.day = today
        log.sentToday += 1
        log.lastSentAt = now
        await store.saveSendLog(log)
        // Taken, not peeked: held by the source until the report is queued (commit below), so a
        // report dropped by a check here gives its input counts to the next one.
        let inputLatency = await inputLatencySource?.take()
        let report = Self.fitted(await build(watchdog: aggregate, metricKit: deliveries, inputLatency: inputLatency,
                                             mainThread: mainThread?.input, fieldData: field.input))
        guard generation == started, !report.hasNoFindings, let body = try? HangReport.encoder.encode(report),
              body.count <= Self.bodyLimit(of: report) else { return }
        let findings = scanner.findings(in: body)
        guard findings.isEmpty else {
            refusedCount += 1
            logger.error("hang report refused by the leak scan: \(findings.count) findings, first \(findings[0].description, privacy: .public)")
            return
        }
        guard generation == started else { return }
        await store.enqueue(body, reportId: report.reportId)
        if inputLatency != nil, generation == started { await inputLatencySource?.commit() }
        if let mainThread, generation == started { mainThreadLedger?.commit(mainThread) }
        if generation == started { await commitFieldData(field, sentIn: report) }
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

    /// Whether `aggregate` holds something this build's wire schema sends: launches alone take no
    /// daily slot while the schema does not carry them.
    private func hasSendable(_ aggregate: StallAggregate) -> Bool {
        builder.wireSchema.carriesLaunches ? !aggregate.isEmpty : !aggregate.isEmptyWithoutLaunches
    }

    /// Whether a queued body would be sent: built by this build (its schema and app), and clean.
    private func isSendable(_ body: Data) -> Bool {
        guard let report = try? JSONDecoder().decode(HangReport.self, from: body), report.schema == builder.wireSchema.rawValue,
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

    /// ``Environment/inputLatency`` when the builder's wire schema carries input latency, else nil:
    /// a build whose reports cannot hold it never records it.
    private var inputLatencySource: (any HangReportInputLatencySource)? {
        builder.wireSchema.carriesInputLatency ? environment.inputLatency : nil
    }

    /// ``Environment/mainThread`` when the builder's wire schema carries it (the app feeds it with a
    /// ``MainThreadActivityFeed``), else nil.
    public nonisolated var mainThreadLedger: MainThreadReportLedger? {
        builder.wireSchema.carriesMainThread ? environment.mainThread : nil
    }

    /// Brings the source's recording to ``isEnabled``. Calls from overlapping ``setEnabled(_:)``
    /// may finish out of order, so each one repeats until its last finished call matches the state.
    private func syncInputLatencyRecording() async {
        guard let source = inputLatencySource else { return }
        var applied: Bool?
        while applied != isEnabled {
            let target = isEnabled
            await source.setRecording(target)
            applied = target
        }
    }

    /// ``Environment/fieldData`` when the builder's wire schema carries field data, else nil: a build whose
    /// reports cannot hold it never reads it.
    private nonisolated var fieldSources: HangReportFieldSources? {
        builder.wireSchema.carriesFieldData ? environment.fieldData : nil
    }

    /// What a report's field data is read from, and the earlier launches it carries.
    struct FieldData {
        /// The builder's input; nil when the schema has no field data.
        var input: HangReportBuilder.FieldDataInput?
        /// The earlier launches in ``input``, by their files.
        var sections: [MetricsLaunchSection<MetricsLaunchContents>] = []

        /// Whether a report should go for it alone (a black box alone is context, not a finding).
        var hasContent: Bool { input?.current != nil || !sections.isEmpty }
    }

    /// The current delta, the first earlier launches that hold a sample (the empty ones are deleted here) and
    /// `blackbox`.
    private func fieldDataInput(blackbox: [TraceBlackBoxUpload.Record]) async -> FieldData {
        guard let sources = fieldSources else { return FieldData() }
        var sections: [MetricsLaunchSection<MetricsLaunchContents>] = []
        for section in await sources.earlierLaunches() where sections.count < HangReport.maxLaunchSections {
            if HangReportBuilder.launchSection(section.contents) == nil {
                await sources.finished(section)
            } else {
                sections.append(section)
            }
        }
        let input = HangReportBuilder.FieldDataInput(current: await sources.currentDelta(), sections: sections.map(\.contents),
                                                     blackbox: blackbox)
        return FieldData(input: input, sections: sections)
    }

    /// Marks what the queued `report` carries as sent: the histograms it kept and every stability count, and the
    /// earlier launches it kept (their files are deleted). What the body cap cut stays for a later report.
    private func commitFieldData(_ field: FieldData, sentIn report: HangReport) async {
        guard let sources = fieldSources else { return }
        if let current = field.input?.current {
            await sources.markSent(HangReportBuilder.sentDelta(current, histograms: report.histograms ?? []))
        }
        let kept = Set((report.launchSections ?? []).map(\.id))
        for section in field.sections where kept.contains(HangReportBuilder.sectionID(section.id)) {
            await sources.finished(section)
        }
    }

    private func build(watchdog: StallAggregate, metricKit: [MetricKitInput], inputLatency: InputLatencySnapshot? = nil,
                       mainThread: HangReportBuilder.MainThreadInput? = nil, fieldData: HangReportBuilder.FieldDataInput? = nil,
                       installId: String? = nil) async -> HangReport {
        let now = environment.now()
        let context = HangReportBuilder.Context(
            reportId: environment.makeReportID(), installId: installId ?? identity.current(), day: Self.day(now), app: environment.app,
            os: environment.os, hardware: environment.hardware, counts: await environment.counts())
        return builder.build(context: context, watchdog: watchdog, metricKit: metricKit, inputLatency: inputLatency,
                             mainThread: mainThread, fieldData: fieldData)
    }

    /// `report` shrunk until it encodes under its schema's body cap (``HangReport/WireSchema/maxBodyBytes``).
    /// The black box goes first (its oldest events), then the input latency, which is context too (the
    /// least frequent rows, then the scroll jank histograms, then the whole block), so hangs keep the room
    /// they had without them; then the shortest hangs (the blocking samples, first in the list, after
    /// every timed one), CPU exceptions and intervals: MetricKit's last ones before the main-turn and
    /// input-queueing histograms, which the builder also keeps at the interval cap
    /// (``HangReportBuilder/addMainThread(_:to:)``); then the earlier launches' sections and the histograms
    /// with the fewest samples, which stay unsent for a later report. The stability counts stay.
    static func fitted(_ report: HangReport) -> HangReport {
        var report = report
        let limit = bodyLimit(of: report)
        while encodedSize(report) > limit {
            if trimBlackBox(&report, limit: limit) || trimInputLatency(&report) { continue }
            if !report.hangs.isEmpty { report.hangs.removeLast() } else if !report.cpuExceptions.isEmpty {
                report.cpuExceptions.removeLast()
            } else if !trimInterval(&report), !trimFieldData(&report) { break }
        }
        return report
    }

    /// The body cap of `report`'s schema.
    static func bodyLimit(of report: HangReport) -> Int {
        HangReport.WireSchema(rawValue: report.schema)?.maxBodyBytes ?? HangReport.maxBodyBytes
    }

    private static func encodedSize(_ report: HangReport) -> Int {
        (try? HangReport.encoder.encode(report).count) ?? 0
    }

    /// Keeps the newest black-box events that fit `limit` (a binary search: a few encodes, not one per
    /// event); none when even one does not. False when there is no black box.
    static func trimBlackBox(_ report: inout HangReport, limit: Int) -> Bool {
        guard let events = report.blackbox, !events.isEmpty else { return false }
        var fits = 0
        var over = events.count
        while over - fits > 1 {
            let middle = (fits + over) / 2
            report.blackbox = Array(events.suffix(middle))
            if encodedSize(report) <= limit { fits = middle } else { over = middle }
        }
        report.blackbox = fits == 0 ? nil : Array(events.suffix(fits))
        return true
    }

    /// Removes the last earlier launch's section, else the histogram with the fewest samples; false when
    /// neither is left.
    static func trimFieldData(_ report: inout HangReport) -> Bool {
        if var sections = report.launchSections, !sections.isEmpty {
            sections.removeLast()
            report.launchSections = sections.isEmpty ? nil : sections
        } else if var histograms = report.histograms,
                  let fewest = histograms.indices.min(by: { histograms[$0].count < histograms[$1].count }) {
            histograms.remove(at: fewest)
            report.histograms = histograms.isEmpty ? nil : histograms
        } else {
            return false
        }
        return true
    }

    /// Removes the last MetricKit interval, else the last main-thread one; false when none is left.
    static func trimInterval(_ report: inout HangReport) -> Bool {
        if let index = report.intervals.lastIndex(where: { $0.category != HangReport.mainThreadCategory }) {
            report.intervals.remove(at: index)
        } else if !report.intervals.isEmpty {
            report.intervals.removeLast()
        } else {
            return false
        }
        return true
    }

    /// Removes one piece of `report`'s input latency; false when it has none left.
    static func trimInputLatency(_ report: inout HangReport) -> Bool {
        if report.inputLatency?.isEmpty == false {
            report.inputLatency?.removeLast()
        } else if report.scrollJank?.histograms.isEmpty == false {
            report.scrollJank?.histograms.removeLast()
        } else if report.inputLatencyBucketEdgesMs != nil || report.inputLatency != nil || report.scrollJank != nil {
            report.inputLatencyBucketEdgesMs = nil
            report.inputLatency = nil
            report.scrollJank = nil
        } else {
            return false
        }
        return true
    }

    /// The UTC day of `date` (`yyyy-MM-dd`).
    static func day(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04ld-%02ld-%02ld", parts.year ?? 1970, parts.month ?? 1, parts.day ?? 1)
    }
}
