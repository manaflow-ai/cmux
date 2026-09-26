import CmuxFoundation
import Foundation
import os

// Crash-safe terminal scrollback (https://github.com/manaflow-ai/cmux/issues/2016,
// https://github.com/manaflow-ai/cmux/issues/2194).
//
// The 8 s session autosave never captures scrollback: capture is a synchronous
// Ghostty VT export on the main thread, too expensive for that cadence. Only
// clean quit, power-off and update relaunch write scrollback into the primary
// snapshot, so a crash or SIGKILL lost every terminal's history.
//
// Checkpoints close that gap at bounded cost:
// - They run at most every `SessionScrollbackCheckpointPolicy.interval`, only
//   after the user has stopped typing for `typingQuietPeriod`.
// - They capture only terminals that produced PTY output since their last
//   checkpoint. The signal is two relaxed atomic loads per PTY read on the
//   Ghostty IO thread (`TerminalScrollbackCheckpointActivity`).
// - The main thread does only Ghostty's VT export into a temp file. Reading,
//   CRLF normalization, the line tail, truncation, encoding and the write all
//   run on a utility queue.
// - At most `maxCapturesPerCheckpoint` exports per checkpoint, one per
//   main-queue turn, stopping early when typing resumes or the exports used
//   `mainThreadCaptureBudget`. A terminal whose export alone exceeded the
//   budget, or failed, waits `slowCaptureBackoff` before it is exported again.
//   The export itself is Ghostty formatting that terminal's whole scrollback
//   under its renderer lock, so one export is the unit that cannot be split.
// - One file per terminal, so an unchanged terminal costs nothing and nothing
//   is cached in memory between checkpoints.
// - After a restore, the restored scrollback is written back as checkpoints
//   for the new panels, so a second crash does not lose it.
// - Restore merges checkpoints into the startup snapshot only after an unclean
//   exit, and a checkpoint never overrides a newer scrollback-bearing save.

/// Scheduling, idle gating and change-detection decisions for scrollback checkpoints.
enum SessionScrollbackCheckpointPolicy {
    /// Minimum time between two checkpoints.
    static let interval: TimeInterval = 60
    /// A checkpoint starts, and each capture proceeds, only after this long without a keystroke.
    static let typingQuietPeriod: TimeInterval = 5
    /// Upper bound on Ghostty VT exports per checkpoint.
    static let maxCapturesPerCheckpoint = 3
    /// No further export is started in a checkpoint once exports have used this much main-thread time.
    static let mainThreadCaptureBudget: TimeInterval = 0.05
    /// A terminal whose export exceeded `mainThreadCaptureBudget`, or failed, is skipped this long.
    static let slowCaptureBackoff: TimeInterval = 600

    /// Checkpoints follow session restore: when restore is disabled there is nothing to restore
    /// into, and automated test runs must not write into the real application support directory.
    static func isEnabled(environment: [String: String]) -> Bool {
        environment["CMUX_DISABLE_SESSION_RESTORE"] != "1"
            && !SessionRestorePolicy.isRunningUnderAutomatedTests(environment: environment)
    }

    static func isTypingQuiet(secondsSinceTyping: TimeInterval?) -> Bool {
        guard let secondsSinceTyping else { return true }
        return secondsSinceTyping >= typingQuietPeriod
    }

    static func isCheckpointDue(
        now: TimeInterval,
        lastCheckpointAt: TimeInterval,
        interval: TimeInterval = SessionScrollbackCheckpointPolicy.interval
    ) -> Bool {
        now - lastCheckpointAt >= interval
    }

    struct Candidate: Equatable, Sendable {
        let panelId: UUID
        /// False when the session policy would not persist this terminal's scrollback right now.
        let isEligible: Bool
        /// Whether the terminal produced output since its last capture; nil when it has no live runtime.
        let hasPendingOutput: Bool?
    }

    struct Plan: Equatable, Sendable {
        /// Terminals to capture, least recently captured first.
        var captures: [UUID]
        /// Terminals whose existing checkpoint must be deleted.
        var removals: Set<UUID>
        /// Every live terminal; checkpoint files for other panels are pruned.
        var livePanelIds: Set<UUID>
    }

    static func plan(
        candidates: [Candidate],
        lastCapturedAt: [UUID: TimeInterval],
        deferredUntil: [UUID: TimeInterval] = [:],
        now: TimeInterval = 0,
        maxCaptures: Int = SessionScrollbackCheckpointPolicy.maxCapturesPerCheckpoint
    ) -> Plan {
        var removals = Set<UUID>()
        var pending: [UUID] = []
        for candidate in candidates {
            if !candidate.isEligible {
                removals.insert(candidate.panelId)
            } else if candidate.hasPendingOutput == true,
                      (deferredUntil[candidate.panelId] ?? -.infinity) <= now {
                pending.append(candidate.panelId)
            }
        }
        pending.sort { lhs, rhs in
            let lhsAt = lastCapturedAt[lhs] ?? -.infinity
            let rhsAt = lastCapturedAt[rhs] ?? -.infinity
            if lhsAt != rhsAt { return lhsAt < rhsAt }
            return lhs.uuidString < rhs.uuidString
        }
        return Plan(
            captures: Array(pending.prefix(max(0, maxCaptures))),
            removals: removals,
            livePanelIds: Set(candidates.map(\.panelId))
        )
    }
}

/// Per-runtime output flags, set from the Ghostty PTY tee.
final class TerminalScrollbackOutputFlags: Sendable {
    /// Output since the last capture began.
    let pending = AtomicBooleanGate(true)
    /// Output since the checkpoint planned this terminal's capture.
    let recent = AtomicBooleanGate(false)
}

/// Per-surface "output since last checkpoint" flags.
final class TerminalScrollbackCheckpointActivity: @unchecked Sendable {
    static let shared = TerminalScrollbackCheckpointActivity()

    private let flags = OSAllocatedUnfairLock(initialState: [UUID: TerminalScrollbackOutputFlags]())

    /// Registers a new runtime for `surfaceID`. A new runtime starts pending so it is captured once.
    func register(surfaceID: UUID) -> TerminalScrollbackOutputFlags {
        let created = TerminalScrollbackOutputFlags()
        flags.withLock { $0[surfaceID] = created }
        return created
    }

    /// Removes `registration` unless a newer runtime for the surface already replaced it.
    func unregister(surfaceID: UUID, registration: TerminalScrollbackOutputFlags) {
        flags.withLock { state in
            if state[surfaceID] === registration {
                state.removeValue(forKey: surfaceID)
            }
        }
    }

    /// Called on the PTY read thread for every output chunk. Stores only on clear-to-set transitions.
    @inline(__always)
    static func recordOutput(_ flags: TerminalScrollbackOutputFlags) {
        if !flags.pending.loadRelaxed() {
            flags.pending.storeRelease(true)
        }
        if !flags.recent.loadRelaxed() {
            flags.recent.storeRelease(true)
        }
    }

    private func registration(_ surfaceID: UUID) -> TerminalScrollbackOutputFlags? {
        flags.withLock { $0[surfaceID] }
    }

    func hasPendingOutput(surfaceID: UUID) -> Bool? {
        registration(surfaceID)?.pending.loadAcquire()
    }

    /// Marks the start of the settle window, at least one main-queue turn before the capture.
    func clearRecentOutput(surfaceID: UUID) {
        registration(surfaceID)?.recent.storeRelease(false)
    }

    /// Clears the pending flag before a capture, so output that races the capture marks the
    /// terminal again. Returns whether output arrived since `clearRecentOutput`: the PTY tee runs
    /// before Ghostty parses those bytes, so they may be missing from this capture.
    func beginCapture(surfaceID: UUID) -> Bool {
        guard let registration = registration(surfaceID) else { return false }
        registration.pending.storeRelease(false)
        return registration.recent.loadAcquire()
    }

    /// Leaves the terminal for the next checkpoint (failed capture, write, or unsettled output).
    func markPending(surfaceID: UUID) {
        registration(surfaceID)?.pending.storeRelease(true)
    }
}

/// One terminal's checkpointed scrollback.
struct SessionScrollbackCheckpointRecord: Codable, Equatable, Sendable {
    static let currentVersion = 1

    var version: Int
    var panelId: UUID
    /// Seconds since 1970, the clock `AppSessionSnapshot.createdAt` uses.
    var capturedAt: TimeInterval
    var scrollback: String
}

struct SessionScrollbackCheckpointCapture: Sendable {
    let panelId: UUID
    let surfaceId: UUID
    let capturedAt: TimeInterval
    /// Produces the captured text off the main thread (reads and trims Ghostty's
    /// export file); nil when the capture failed.
    let finish: @Sendable () -> String?
    /// Deletes the export file without reading it; used when the capture is dropped.
    var discard: @Sendable () -> Void = {}
}

/// The main-thread half of a capture hands back both halves of the export.
struct SessionScrollbackCheckpointExport: Sendable {
    let finish: @Sendable () -> String?
    let discard: @Sendable () -> Void
}

struct SessionScrollbackCheckpointWriteBatch: Sendable {
    var captures: [SessionScrollbackCheckpointCapture]
    var removals: Set<UUID>
    /// Every live terminal; files for other panels are pruned. Nil skips pruning.
    var livePanelIds: Set<UUID>?
}

/// One JSON file per terminal next to the primary session snapshot.
struct SessionScrollbackCheckpointStore: Sendable {
    let directoryURL: URL

    init(directoryURL: URL) {
        self.directoryURL = directoryURL
    }

    /// `…/cmux/session-<bundle>.json` keeps its checkpoints in `…/cmux/session-<bundle>-scrollback/`.
    init(primarySnapshotURL: URL) {
        let stem = primarySnapshotURL.deletingPathExtension().lastPathComponent
        self.directoryURL = primarySnapshotURL
            .deletingLastPathComponent()
            .appendingPathComponent("\(stem)-scrollback", isDirectory: true)
    }

    func fileURL(panelId: UUID) -> URL {
        directoryURL.appendingPathComponent("\(panelId.uuidString).json", isDirectory: false)
    }

    /// Writes captures, deletes removals and prunes files of panels that no longer exist.
    /// Returns the surfaces whose capture could not be persisted.
    @discardableResult
    func apply(
        _ batch: SessionScrollbackCheckpointWriteBatch,
        fileManager: FileManager = .default
    ) -> Set<UUID> {
        var removals = batch.removals
        var failedSurfaceIds = Set<UUID>()
        if !batch.captures.isEmpty {
            try? fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        let encoder = JSONEncoder()
        for capture in batch.captures {
            guard let captured = capture.finish() else {
                failedSurfaceIds.insert(capture.surfaceId)
                continue
            }
            guard let scrollback = SessionPersistencePolicy.truncatedScrollback(captured),
                  scrollback.contains(where: { !$0.isWhitespace }) else {
                // An empty terminal restores empty, like the quit path.
                removals.insert(capture.panelId)
                continue
            }
            let record = SessionScrollbackCheckpointRecord(
                version: SessionScrollbackCheckpointRecord.currentVersion,
                panelId: capture.panelId,
                capturedAt: capture.capturedAt,
                scrollback: scrollback
            )
            do {
                try encoder.encode(record).write(to: fileURL(panelId: capture.panelId), options: .atomic)
            } catch {
                failedSurfaceIds.insert(capture.surfaceId)
            }
        }
        for panelId in removals {
            try? fileManager.removeItem(at: fileURL(panelId: panelId))
        }
        if let livePanelIds = batch.livePanelIds {
            prune(keeping: livePanelIds, fileManager: fileManager)
        }
        return failedSurfaceIds
    }

    /// Applies `batch` and leaves every failed capture pending for the next checkpoint.
    func applyMarkingFailuresPending(
        _ batch: SessionScrollbackCheckpointWriteBatch,
        activity: TerminalScrollbackCheckpointActivity
    ) {
        for surfaceId in apply(batch) {
            activity.markPending(surfaceID: surfaceId)
        }
    }

    func prune(keeping livePanelIds: Set<UUID>, fileManager: FileManager = .default) {
        guard let names = try? fileManager.contentsOfDirectory(atPath: directoryURL.path) else { return }
        for name in names {
            let url = directoryURL.appendingPathComponent(name, isDirectory: false)
            guard url.pathExtension == "json",
                  let panelId = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
                  !livePanelIds.contains(panelId) else {
                continue
            }
            try? fileManager.removeItem(at: url)
        }
    }

    func loadRecords(panelIds: Set<UUID>) -> [UUID: SessionScrollbackCheckpointRecord] {
        let decoder = JSONDecoder()
        var records: [UUID: SessionScrollbackCheckpointRecord] = [:]
        for panelId in panelIds {
            guard let data = try? Data(contentsOf: fileURL(panelId: panelId)),
                  let record = try? decoder.decode(SessionScrollbackCheckpointRecord.self, from: data),
                  record.version == SessionScrollbackCheckpointRecord.currentVersion,
                  record.panelId == panelId else {
                continue
            }
            records[panelId] = record
        }
        return records
    }

    /// Fills terminal scrollback in a crash-recovered snapshot from checkpoints newer than it.
    func merging(into snapshot: AppSessionSnapshot) -> AppSessionSnapshot {
        let panelIds = SessionScrollbackCheckpointMerge.terminalPanelIds(in: snapshot)
        guard !panelIds.isEmpty else { return snapshot }
        let records = loadRecords(panelIds: panelIds)
        guard !records.isEmpty else { return snapshot }
        return SessionScrollbackCheckpointMerge.merging(records, into: snapshot)
    }
}

enum SessionScrollbackCheckpointMerge {
    /// Chooses between the snapshot's own scrollback and a checkpoint.
    ///
    /// A snapshot saved with scrollback (quit, power-off, update relaunch) records
    /// `scrollbackCapturedAt`; when that is at least as new as the checkpoint, the
    /// snapshot wins even with no scrollback, because it omitted it on purpose
    /// (running command, cleared terminal). The 8 s autosave never captures
    /// scrollback and leaves the marker nil, so its snapshot is treated as having
    /// no scrollback evidence. Legacy snapshots without the marker keep their own
    /// non-empty scrollback when they are newer.
    static func resolvedScrollback(
        snapshotScrollback: String?,
        snapshotCreatedAt: TimeInterval,
        snapshotScrollbackCapturedAt: TimeInterval?,
        checkpoint: SessionScrollbackCheckpointRecord?
    ) -> String? {
        guard let checkpoint else { return snapshotScrollback }
        if let scrollbackCapturedAt = snapshotScrollbackCapturedAt {
            return scrollbackCapturedAt >= checkpoint.capturedAt ? snapshotScrollback : checkpoint.scrollback
        }
        if let snapshotScrollback, !snapshotScrollback.isEmpty, snapshotCreatedAt >= checkpoint.capturedAt {
            return snapshotScrollback
        }
        return checkpoint.scrollback
    }

    static func terminalPanelIds(in snapshot: AppSessionSnapshot) -> Set<UUID> {
        var ids = Set<UUID>()
        func collect(_ panels: [SessionPanelSnapshot]) {
            for panel in panels where panel.terminal != nil {
                ids.insert(panel.id)
            }
        }
        for window in snapshot.windows {
            for workspace in window.tabManager.workspaces {
                collect(workspace.panels)
                if let dock = workspace.dock { collect(dock.panels) }
            }
            if let dock = window.dock { collect(dock.panels) }
        }
        return ids
    }

    static func merging(
        _ records: [UUID: SessionScrollbackCheckpointRecord],
        into snapshot: AppSessionSnapshot
    ) -> AppSessionSnapshot {
        let createdAt = snapshot.createdAt
        let scrollbackCapturedAt = snapshot.scrollbackCapturedAt
        func merge(_ panels: inout [SessionPanelSnapshot]) {
            for index in panels.indices {
                guard panels[index].terminal != nil,
                      let record = records[panels[index].id] else { continue }
                panels[index].terminal?.scrollback = resolvedScrollback(
                    snapshotScrollback: panels[index].terminal?.scrollback,
                    snapshotCreatedAt: createdAt,
                    snapshotScrollbackCapturedAt: scrollbackCapturedAt,
                    checkpoint: record
                )
            }
        }
        var merged = snapshot
        for windowIndex in merged.windows.indices {
            for workspaceIndex in merged.windows[windowIndex].tabManager.workspaces.indices {
                merge(&merged.windows[windowIndex].tabManager.workspaces[workspaceIndex].panels)
                merge(&merged.windows[windowIndex].tabManager.workspaces[workspaceIndex].dock.panelsOrEmpty)
            }
            merge(&merged.windows[windowIndex].dock.panelsOrEmpty)
        }
        return merged
    }
}

private extension Optional where Wrapped == SessionSplitContainerSnapshot {
    /// Mutable access to an optional dock's panels; writes to a nil dock are dropped.
    var panelsOrEmpty: [SessionPanelSnapshot] {
        get { self?.panels ?? [] }
        set { self?.panels = newValue }
    }
}

/// Runs scrollback checkpoints on the main actor. All environment access is
/// injected so scheduling, gating and change detection are testable.
@MainActor
final class SessionScrollbackCheckpointCoordinator {
    struct Candidate {
        let panelId: UUID
        let surfaceId: UUID
        let isEligible: Bool
        /// Main-thread half of the capture (Ghostty's VT export). Returns the
        /// off-main reader and a cheap discard for the export file, or nil on failure.
        let beginCapture: () -> SessionScrollbackCheckpointExport?
    }

    struct Seed {
        let panelId: UUID
        let surfaceId: UUID
        let scrollback: String
    }

    struct Environment {
        /// Monotonic seconds for scheduling.
        var uptime: () -> TimeInterval
        /// Seconds since 1970 for record timestamps.
        var wallClock: () -> TimeInterval
        /// False while terminating or while a session restore is pending or running.
        var canCheckpoint: () -> Bool
        var secondsSinceTyping: () -> TimeInterval?
        var candidates: () -> [Candidate]
        /// Defers work to a later main-queue turn.
        var scheduleNextCapture: (@escaping @MainActor () -> Void) -> Void
        /// Hands the batch to background I/O.
        var persist: (SessionScrollbackCheckpointWriteBatch) -> Void
    }

    private let environment: Environment
    private let activity: TerminalScrollbackCheckpointActivity
    private var lastCheckpointAt: TimeInterval
    private var lastCapturedAt: [UUID: TimeInterval] = [:]
    private var deferredUntil: [UUID: TimeInterval] = [:]
    private(set) var isCheckpointInFlight = false

    init(
        environment: Environment,
        activity: TerminalScrollbackCheckpointActivity = .shared
    ) {
        self.environment = environment
        self.activity = activity
        // The first checkpoint waits a full interval after launch.
        self.lastCheckpointAt = environment.uptime()
    }

    /// Writes already-known scrollback (a just-restored session) as checkpoints
    /// without a VT export, so a crash before the next checkpoint keeps it.
    func seed(_ seeds: [Seed]) {
        guard !seeds.isEmpty else { return }
        let capturedAt = environment.wallClock()
        environment.persist(SessionScrollbackCheckpointWriteBatch(
            captures: seeds.map { seed in
                let scrollback = seed.scrollback
                return SessionScrollbackCheckpointCapture(
                    panelId: seed.panelId,
                    surfaceId: seed.surfaceId,
                    capturedAt: capturedAt,
                    finish: { scrollback }
                )
            },
            removals: [],
            livePanelIds: nil
        ))
    }

    /// Cheap unless a checkpoint is due; safe to call from the 8 s autosave timer.
    @discardableResult
    func tickIfDue() -> Bool {
        guard !isCheckpointInFlight, environment.canCheckpoint() else { return false }
        let now = environment.uptime()
        guard SessionScrollbackCheckpointPolicy.isCheckpointDue(now: now, lastCheckpointAt: lastCheckpointAt),
              SessionScrollbackCheckpointPolicy.isTypingQuiet(
                  secondsSinceTyping: environment.secondsSinceTyping()
              ) else {
            return false
        }
        lastCheckpointAt = now

        let candidates = environment.candidates()
        var candidatesById: [UUID: Candidate] = [:]
        for candidate in candidates { candidatesById[candidate.panelId] = candidate }
        let plan = SessionScrollbackCheckpointPolicy.plan(
            candidates: candidates.map {
                SessionScrollbackCheckpointPolicy.Candidate(
                    panelId: $0.panelId,
                    isEligible: $0.isEligible,
                    hasPendingOutput: activity.hasPendingOutput(surfaceID: $0.surfaceId)
                )
            },
            lastCapturedAt: lastCapturedAt,
            deferredUntil: deferredUntil,
            now: now
        )
        lastCapturedAt = lastCapturedAt.filter { plan.livePanelIds.contains($0.key) }
        deferredUntil = deferredUntil.filter { plan.livePanelIds.contains($0.key) && $0.value > now }

        let planned = plan.captures.compactMap { candidatesById[$0] }
        for candidate in planned {
            activity.clearRecentOutput(surfaceID: candidate.surfaceId)
        }
        isCheckpointInFlight = true
        // Start one main-queue turn later so output teed before the settle
        // window opened has a chance to reach Ghostty's parser.
        environment.scheduleNextCapture { [weak self] in
            self?.captureNext(remaining: planned[...], captured: [], spent: 0, plan: plan)
        }
        return true
    }

    private func captureNext(
        remaining: ArraySlice<Candidate>,
        captured: [SessionScrollbackCheckpointCapture],
        spent: TimeInterval,
        plan: SessionScrollbackCheckpointPolicy.Plan
    ) {
        guard environment.canCheckpoint() else {
            // Quit or restore started: the utility queue may not run before
            // exit, so drop the exports now (a synchronous unlink each) and
            // leave those terminals pending. Quit writes its own scrollback.
            for capture in captured {
                capture.discard()
                activity.markPending(surfaceID: capture.surfaceId)
            }
            isCheckpointInFlight = false
            return
        }
        guard let candidate = remaining.first,
              spent < SessionScrollbackCheckpointPolicy.mainThreadCaptureBudget,
              SessionScrollbackCheckpointPolicy.isTypingQuiet(
                  secondsSinceTyping: environment.secondsSinceTyping()
              ) else {
            // Unstarted captures keep their pending flag for the next checkpoint.
            environment.persist(SessionScrollbackCheckpointWriteBatch(
                captures: captured,
                removals: plan.removals,
                livePanelIds: plan.livePanelIds
            ))
            isCheckpointInFlight = false
            return
        }

        let start = environment.uptime()
        let outputSincePlan = activity.beginCapture(surfaceID: candidate.surfaceId)
        let export = candidate.beginCapture()
        let duration = max(0, environment.uptime() - start)
        var captured = captured
        if let export {
            captured.append(SessionScrollbackCheckpointCapture(
                panelId: candidate.panelId,
                surfaceId: candidate.surfaceId,
                capturedAt: environment.wallClock(),
                finish: export.finish,
                discard: export.discard
            ))
            lastCapturedAt[candidate.panelId] = start
            if outputSincePlan {
                // Bytes flagged just before the capture may not have been parsed
                // into it; capture this terminal again next time.
                activity.markPending(surfaceID: candidate.surfaceId)
            }
        } else {
            activity.markPending(surfaceID: candidate.surfaceId)
            deferredUntil[candidate.panelId] = start + SessionScrollbackCheckpointPolicy.slowCaptureBackoff
        }
        if duration > SessionScrollbackCheckpointPolicy.mainThreadCaptureBudget {
            deferredUntil[candidate.panelId] = start + SessionScrollbackCheckpointPolicy.slowCaptureBackoff
        }
        let spent = spent + duration
        let rest = remaining.dropFirst()
        environment.scheduleNextCapture { [weak self] in
            self?.captureNext(remaining: rest, captured: captured, spent: spent, plan: plan)
        }
    }
}
