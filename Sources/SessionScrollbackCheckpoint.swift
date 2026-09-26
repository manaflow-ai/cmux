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
//   checkpoint. The signal is one relaxed atomic load per PTY read on the
//   Ghostty IO thread (`TerminalScrollbackCheckpointActivity`).
// - At most `maxCapturesPerCheckpoint` terminals are captured per checkpoint,
//   one per main-queue turn, stopping early when typing resumes or the
//   main-thread budget is spent. The rest stay pending for the next checkpoint.
// - Truncation, encoding and file I/O happen off the main thread, one file per
//   terminal, so an unchanged terminal costs nothing and nothing is cached in
//   memory between checkpoints.
// - Restore merges checkpoints into the startup snapshot only after an unclean
//   exit, and a checkpoint only replaces snapshot scrollback that is older.

/// Scheduling, idle gating and change-detection decisions for scrollback checkpoints.
enum SessionScrollbackCheckpointPolicy {
    /// Minimum time between two checkpoints.
    static let interval: TimeInterval = 60
    /// A checkpoint starts, and each capture proceeds, only after this long without a keystroke.
    static let typingQuietPeriod: TimeInterval = 5
    /// Upper bound on Ghostty VT exports per checkpoint.
    static let maxCapturesPerCheckpoint = 3
    /// No further capture is started in a checkpoint once captures have used this much main-thread time.
    static let mainThreadCaptureBudget: TimeInterval = 0.05

    /// Checkpoints follow session restore: when restore is disabled there is nothing to restore into.
    static func isEnabled(environment: [String: String]) -> Bool {
        environment["CMUX_DISABLE_SESSION_RESTORE"] != "1"
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
        maxCaptures: Int = SessionScrollbackCheckpointPolicy.maxCapturesPerCheckpoint
    ) -> Plan {
        var removals = Set<UUID>()
        var pending: [UUID] = []
        for candidate in candidates {
            if !candidate.isEligible {
                removals.insert(candidate.panelId)
            } else if candidate.hasPendingOutput == true {
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

/// Per-surface "output since last checkpoint" flags, set from the Ghostty PTY tee.
final class TerminalScrollbackCheckpointActivity: @unchecked Sendable {
    static let shared = TerminalScrollbackCheckpointActivity()

    private let gates = OSAllocatedUnfairLock(initialState: [UUID: AtomicBooleanGate]())

    /// Registers a new runtime for `surfaceID`. A new runtime starts pending so it is captured once.
    func register(surfaceID: UUID) -> AtomicBooleanGate {
        let gate = AtomicBooleanGate(true)
        gates.withLock { $0[surfaceID] = gate }
        return gate
    }

    /// Removes `gate` unless a newer runtime for the surface already replaced it.
    func unregister(surfaceID: UUID, gate: AtomicBooleanGate) {
        gates.withLock { state in
            if state[surfaceID] === gate {
                state.removeValue(forKey: surfaceID)
            }
        }
    }

    /// Called on the PTY read thread for every output chunk. Stores only on the idle-to-pending transition.
    @inline(__always)
    static func recordOutput(_ gate: AtomicBooleanGate) {
        if !gate.loadRelaxed() {
            gate.storeRelease(true)
        }
    }

    func hasPendingOutput(surfaceID: UUID) -> Bool? {
        gates.withLock { $0[surfaceID] }?.loadAcquire()
    }

    /// Clears the flag before a capture, so output that races the capture marks the terminal again.
    func beginCapture(surfaceID: UUID) {
        gates.withLock { $0[surfaceID] }?.storeRelease(false)
    }

    /// Restores the flag after a failed capture.
    func markPending(surfaceID: UUID) {
        gates.withLock { $0[surfaceID] }?.storeRelease(true)
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
    let capturedAt: TimeInterval
    /// Untruncated capture; normalized off the main thread.
    let scrollback: String
}

struct SessionScrollbackCheckpointWriteBatch: Sendable {
    var captures: [SessionScrollbackCheckpointCapture]
    var removals: Set<UUID>
    var livePanelIds: Set<UUID>
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
    func apply(_ batch: SessionScrollbackCheckpointWriteBatch, fileManager: FileManager = .default) {
        var removals = batch.removals
        if !batch.captures.isEmpty {
            try? fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        let encoder = JSONEncoder()
        for capture in batch.captures {
            guard let scrollback = SessionPersistencePolicy.truncatedScrollback(capture.scrollback),
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
            guard let data = try? encoder.encode(record) else { continue }
            try? data.write(to: fileURL(panelId: capture.panelId), options: .atomic)
        }
        for panelId in removals {
            try? fileManager.removeItem(at: fileURL(panelId: panelId))
        }
        prune(keeping: batch.livePanelIds, fileManager: fileManager)
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
    /// The newest of the snapshot's own scrollback and the checkpoint wins.
    static func resolvedScrollback(
        snapshotScrollback: String?,
        snapshotCreatedAt: TimeInterval,
        checkpoint: SessionScrollbackCheckpointRecord?
    ) -> String? {
        guard let checkpoint else { return snapshotScrollback }
        guard let snapshotScrollback, !snapshotScrollback.isEmpty else { return checkpoint.scrollback }
        return checkpoint.capturedAt > snapshotCreatedAt ? checkpoint.scrollback : snapshotScrollback
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
        func merge(_ panels: inout [SessionPanelSnapshot]) {
            for index in panels.indices {
                guard panels[index].terminal != nil,
                      let record = records[panels[index].id] else { continue }
                panels[index].terminal?.scrollback = resolvedScrollback(
                    snapshotScrollback: panels[index].terminal?.scrollback,
                    snapshotCreatedAt: createdAt,
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
        /// Synchronous capture of the terminal's scrollback (a Ghostty VT export); nil on failure.
        let capture: () -> String?
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
        /// Defers the next capture to a later main-queue turn.
        var scheduleNextCapture: (@escaping @MainActor () -> Void) -> Void
        /// Hands the batch to background I/O.
        var persist: (SessionScrollbackCheckpointWriteBatch) -> Void
    }

    private let environment: Environment
    private let activity: TerminalScrollbackCheckpointActivity
    private var lastCheckpointAt: TimeInterval
    private var lastCapturedAt: [UUID: TimeInterval] = [:]
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
            lastCapturedAt: lastCapturedAt
        )
        lastCapturedAt = lastCapturedAt.filter { plan.livePanelIds.contains($0.key) }

        isCheckpointInFlight = true
        captureNext(
            remaining: plan.captures.compactMap { candidatesById[$0] }[...],
            captured: [],
            capturedSurfaceIds: [],
            spent: 0,
            plan: plan
        )
        return true
    }

    private func captureNext(
        remaining: ArraySlice<Candidate>,
        captured: [SessionScrollbackCheckpointCapture],
        capturedSurfaceIds: [UUID],
        spent: TimeInterval,
        plan: SessionScrollbackCheckpointPolicy.Plan
    ) {
        guard environment.canCheckpoint() else {
            // Quit and restore write their own snapshot; drop this checkpoint
            // and leave the dropped captures pending for the next one.
            for surfaceId in capturedSurfaceIds {
                activity.markPending(surfaceID: surfaceId)
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
        activity.beginCapture(surfaceID: candidate.surfaceId)
        var captured = captured
        var capturedSurfaceIds = capturedSurfaceIds
        if let scrollback = candidate.capture() {
            captured.append(SessionScrollbackCheckpointCapture(
                panelId: candidate.panelId,
                capturedAt: environment.wallClock(),
                scrollback: scrollback
            ))
            capturedSurfaceIds.append(candidate.surfaceId)
            lastCapturedAt[candidate.panelId] = start
        } else {
            activity.markPending(surfaceID: candidate.surfaceId)
        }
        let spent = spent + max(0, environment.uptime() - start)
        let rest = remaining.dropFirst()
        environment.scheduleNextCapture { [weak self] in
            self?.captureNext(
                remaining: rest,
                captured: captured,
                capturedSurfaceIds: capturedSurfaceIds,
                spent: spent,
                plan: plan
            )
        }
    }
}
