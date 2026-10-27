import Foundation
import os

extension HangReportService {
    /// What the service records and sends (``HangReportAskPolicy/mode(hangReports:performanceData:fullReports:)``).
    public enum Mode: Sendable, Hashable {
        /// Nothing is recorded or sent.
        case off
        /// `diagnostics.performanceData`, in any channel: schema 3's catalog histograms and stability counts only,
        /// this launch's and earlier launches' (``HangReport/aggregatesOnly``). No hang or blocking sample, black
        /// box, MetricKit payload, interval, input latency, feature or blocking site is recorded or sent.
        case aggregates
        /// `diagnostics.hangReports` (NIGHTLY): everything the builder's wire schema carries.
        case full
    }

    /// Whether anything is recorded and sent (``mode`` is not ``Mode/off``).
    public var isEnabled: Bool { mode != .off }

    /// Follows `diagnostics.hangReports` alone: on is ``Mode/full``.
    public func setEnabled(_ on: Bool) async {
        await setMode(on ? .full : .off)
    }

    /// One aggregates report (``Mode/aggregates``): this launch's delta and the earlier launches' sections through
    /// the same daily cap, body cap, leak scan and outbox as a hang report. Its field data is marked sent once the
    /// server took it, as a hang report's is.
    func sendAggregatesOnce() async {
        guard await allowed() else { return }
        let started = generation
        guard let slot = await dailySlot(started: started) else { return }
        let field = await fieldDataInput(pruning: true)
        guard generation == started, field.hasContent else { return }
        await spend(slot)
        let report = Self.fitted(await build(watchdog: StallAggregate(), metricKit: [], fieldData: field.input).aggregatesOnly)
        guard report.hasFieldData, await queue(report, field: field, started: started) else { return }
        await flushOutbox()
    }

    /// Today's send log and the time read, when another report may go today; nil at ``dailyLimit`` or when the
    /// mode changed meanwhile (`started`, the generation the caller began in).
    func dailySlot(started: Int) async -> (log: HangReportStore.SendLog, now: Date)? {
        let now = environment.now()
        var log = await store.sendLog()
        guard generation == started else { return nil }
        if log.day != Self.day(now) { log = HangReportStore.SendLog() }
        return log.sentToday < Self.dailyLimit ? (log, now) : nil
    }

    /// Takes the report slot ``dailySlot(started:)`` found.
    func spend(_ slot: (log: HangReportStore.SendLog, now: Date)) async {
        var log = slot.log
        log.day = Self.day(slot.now)
        log.sentToday += 1
        log.lastSentAt = slot.now
        await store.saveSendLog(log)
    }

    /// Queues `report` when it fits its schema's body cap and the leak scan finds nothing, with what its field data
    /// marks sent once the server takes it, and keeps its readable copy (View Hang Report). False when it was not
    /// queued: refused, or the mode changed since `started`.
    func queue(_ report: HangReport, field: FieldData, started: Int) async -> Bool {
        guard generation == started, let body = try? HangReport.encoder.encode(report),
              body.count <= Self.bodyLimit(of: report) else { return false }
        let findings = scanner.findings(in: body)
        guard findings.isEmpty else {
            refusedCount += 1
            let first = findings.first?.description ?? ""
            logger.error("hang report refused by the leak scan: \(findings.count) findings, first \(first, privacy: .public)")
            return false
        }
        guard generation == started else { return false }
        // Recorded before the body is queued, so a flush that sends it finds what to mark sent.
        if let commit = FieldCommit(field, sentIn: report) { fieldCommits[report.reportId] = commit }
        await store.enqueue(body, reportId: report.reportId)
        // The readable copy is the queued body's, written only while the mode it was built in holds.
        if generation == started, let readable = try? HangReport.readableEncoder.encode(report) { await store.saveLastReport(readable) }
        return true
    }

    /// Drops the MetricKit deliveries, the queued reports and what a quit saved; a queued report's field data is
    /// free for a later one.
    func dropQueued() async {
        waiting = []
        fieldCommits = [:]
        await store.clearQueued()
    }
}
