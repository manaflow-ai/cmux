import CmuxNextDaemon
import CmuxNextSettings
import Foundation
import os

/// Checks the world and geometry invariants (plans/cmux-next/input-spec.md 2.5, 2.6)
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
    private let frames = FrameBatcher(owner: "InputInvariantMonitor")
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
        // A window stays unsettled for a moment after a switch; unsettled at
        // the check and again at its confirmation, its presentation is stuck
        // (and W1-W4 would never run for it).
        let violations = result.violations + result.unsettled.map {
            InputViolation(invariant: .presentationSettles, window: $0, detail: "the focused pane does not present the targeted tab")
        }
        let current = Set(violations.map(\.signature))
        reported.formIntersection(current)
        let confirmed = current.intersection(suspected).subtracting(reported)
        suspected = current.subtracting(reported)
        if !confirmed.isEmpty {
            record(violations.filter { confirmed.contains($0.signature) })
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
        var result = InputInvariants.world(InputObservationBuilder.observe(services))
        result.violations += Self.pageGeometry(services)
        result.violations += Self.tabConservation(services)
        result.violations += Self.mirrorWrites(services)
        result.violations += services.hoverCards.singleCardViolations().map {
            InputViolation(invariant: .hoverCardSingle, window: nil, detail: $0)
        }
        lastResult = result
        return result
    }

    /// G1 (input-spec.md 2.6): the Chromium page geometry invariant owned by
    /// `ChildPageGeometry`, sampled per window so each violation names its
    /// window. Skips a window in a live resize (the fork follows each step;
    /// the check runs once the resize ends).
    static func pageGeometry(_ services: AppServices) -> [InputViolation] {
        services.windows.controllers.flatMap { controller -> [InputViolation] in
            guard controller.window?.inLiveResize != true else { return [] }
            let (hosts, pages) = ChildPageGeometry.sample(controller)
            return ChildPageGeometry.mismatches(hosts: hosts, pages: pages).map {
                InputViolation(invariant: .chromiumGeometry, window: controller.state.id, detail: $0)
            }
        }
    }

    /// DP1 (plans/cmux-next/layout-invariants.md): once no tab drag is in
    /// flight, every strip shows exactly the tabs its pane holds, none
    /// hidden (a drag's presentation that never ended) and none extra.
    static func tabConservation(_ services: AppServices) -> [InputViolation] {
        guard !services.dragSession.hasDragInFlight else { return [] }
        return services.windows.controllers.flatMap { controller -> [InputViolation] in
            (controller.content?.panes.values.map { $0 } ?? []).compactMap { pane in
                // A strip out of the window does not observe its model.
                guard pane.view.stripView.window != nil else { return nil }
                let shown = pane.view.stripView.presentedTabIDs.map(\.rawValue)
                let held = pane.stripModel.orderedTabs.map(\.id.rawValue)
                guard Set(shown) != Set(held) || shown.count != held.count else { return nil }
                return InputViolation(invariant: .stripShowsPaneTabs, window: controller.state.id,
                                      detail: "pane \(pane.paneKey) shows \(shown) but holds \(held)")
            }
        }
    }

    /// M1 (plans/cmux-next/ownership.md step 4): mirror writes outside
    /// daemon apply and the intent overlay, found by each store's
    /// debug-build check (DaemonStore+MirrorCheck.swift). Each stays
    /// listed (and reported once) for the life of its store.
    static func mirrorWrites(_ services: AppServices) -> [InputViolation] {
        services.machines.daemons.flatMap { daemon in
            daemon.store.mirrorViolations.map {
                InputViolation(invariant: .mirrorSingleWriter, window: nil, detail: "\(daemon.machineID): \($0)")
            }
        }
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
        // The UI snapshots are read here (main actor); encoding and pretty-printing them (about
        // 30 ms per report, R81 trace) run off the main actor with the write.
        let extras: [String: CmuxNextSettings.JSONValue] = [
            "debug_focus": DebugFocus.report(services: services),
            "debug_surfaces": SurfaceDiagnosticsReport.make(services),
            "debug_layers": DebugLayers.report(services: services),
        ]
        let store = store
        Task.detached(priority: .utility) {
            if let data = Self.fileData(report, extras: extras) { store.write(data, for: report) }
        }
        for line in report.summary {
            #if DEBUG
            logger.fault("input desync \(line, privacy: .public)")
            #else
            logger.error("input desync \(line, privacy: .public)")
            #endif
        }
        return report
    }

    /// The report plus `debug.focus`, `debug.surfaces` and `debug.layers` captured with it.
    nonisolated private static func fileData(_ report: DesyncReport, extras: [String: CmuxNextSettings.JSONValue]) -> Data? {
        guard let encoded = try? DesyncReport.encoder.encode(report), case .object(var object)? = try? CmuxNextSettings.JSONValue.parse(encoded) else { return nil }
        object.merge(extras) { _, extra in extra }
        return Data(CmuxNextSettings.JSONValue.object(object).prettyText().utf8)
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
