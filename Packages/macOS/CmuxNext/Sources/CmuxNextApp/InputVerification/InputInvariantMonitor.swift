import CmuxNextSettings
import Foundation
import os

/// Checks the world invariants (plans/cmux-next/input-spec.md section 2.4)
/// against live AppKit, Ghostty and Chromium state once input settles, and
/// turns a desync into a `DesyncReport` on disk (`debug.desync`). Nothing is
/// repaired here: a broken rule stays visible and replayable.
///
/// Event-driven like `SurfaceInvariantMonitor`: after a focus transition,
/// key or mouse event or presentation change it waits `settleFrames`
/// display frames, checks, and confirms a violation with a second check one
/// settle later (async focus reports, such as Chromium's, land in between).
/// Only a violation present in both checks is reported, once until it
/// clears. An idle app runs no display link.
final class InputInvariantMonitor {
    static let settleFrames = 12
    static let reportsKept = 16
    static let journalTail = 512

    weak var services: AppServices?
    private let frames = DisplayLinkFrameScheduler()
    private let store: DesyncReportStore
    private let tag: String?
    private var remaining = 0
    /// Signatures seen at the last check, waiting for confirmation.
    private var suspected: Set<String> = []
    /// Signatures already reported and still broken.
    private var reported: Set<String> = []
    /// The next check is the confirmation of `suspected`.
    private var confirming = false
    private(set) var checks = 0
    private(set) var lastResult: InputInvariants.WorldResult?
    private(set) var reports: [DesyncReport] = []
    private(set) var reportCount = 0
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "app.input")

    init(tag: String?) {
        self.tag = tag
        store = DesyncReportStore(tag: tag)
    }

    var directory: String? { store.directory?.path(percentEncoded: false) }

    /// Input or focus changed; check once it settles.
    func noteChange() {
        let idle = remaining == 0
        remaining = Self.settleFrames
        if idle { scheduleStep() }
    }

    private func scheduleStep() {
        frames.scheduleFrame { [weak self] in self?.step() }
    }

    private func step() {
        remaining -= 1
        guard remaining <= 0 else { return scheduleStep() }
        remaining = 0
        settle()
    }

    private func settle() {
        guard let result = check() else { return }
        let current = Set(result.violations.map(\.signature))
        reported.formIntersection(current)
        let confirmed = current.intersection(suspected).subtracting(reported)
        suspected = current.subtracting(reported)
        if !confirmed.isEmpty {
            record(result.violations.filter { confirmed.contains($0.signature) })
            reported.formUnion(confirmed)
            suspected.subtract(confirmed)
        }
        // Something is broken but unconfirmed: look again once, one settle
        // later (bounded, so a flickering rule cannot keep a display link).
        if !suspected.isEmpty, !confirming {
            confirming = true
            noteChange()
        } else {
            confirming = false
        }
    }

    /// Checks now (no confirmation). Public for `debug.desync`.
    @discardableResult
    func check() -> InputInvariants.WorldResult? {
        guard let services else { return nil }
        checks += 1
        let result = InputInvariants.world(InputObservationBuilder.observe(services))
        lastResult = result
        return result
    }

    /// Records a report now for `violations` (the monitor, or `debug.desync`
    /// with `report: true` to capture on demand).
    @discardableResult
    func record(_ violations: [InputViolation]) -> DesyncReport? {
        guard let services else { return nil }
        reportCount += 1
        let now = Date()
        let journal = InputJournal.shared
        journal.append(window: violations.first?.window, .desync(violations.map { "\($0.invariant.rawValue) \($0.detail)" }))
        let report = DesyncReport(
            id: "desync-\(Self.stamp(now))-\(String(format: "%04d", reportCount))",
            sequence: reportCount,
            createdAt: now,
            uptimeNanos: clock_gettime_nsec_np(CLOCK_UPTIME_RAW),
            tag: tag,
            violations: violations,
            observation: InputObservationBuilder.observe(services),
            journal: journal.entries(last: Self.journalTail),
            journalStats: journal.stats
        )
        reports.append(report)
        if reports.count > Self.reportsKept { reports.removeFirst(reports.count - Self.reportsKept) }
        if let data = Self.fileData(report, services: services) { store.write(data, for: report) }
        for line in report.summary {
            #if DEBUG
            logger.fault("input desync \(line, privacy: .public)")
            #else
            logger.error("input desync \(line, privacy: .public)")
            #endif
        }
        return report
    }

    /// The report plus `debug.focus` and `debug.surfaces` at capture time.
    private static func fileData(_ report: DesyncReport, services: AppServices) -> Data? {
        guard let encoded = try? DesyncReport.encoder.encode(report), case .object(var object)? = try? JSONValue.parse(encoded) else { return nil }
        object["debug_focus"] = DebugFocus.report(services: services)
        object["debug_surfaces"] = SurfaceDiagnosticsReport.make(services)
        return Data(JSONValue.object(object).prettyText().utf8)
    }

    func clear() {
        reports.removeAll()
        suspected.removeAll()
        reported.removeAll()
    }

    func url(of report: DesyncReport) -> String? { store.url(for: report)?.path(percentEncoded: false) }

    private static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss"
        return formatter.string(from: date)
    }
}
