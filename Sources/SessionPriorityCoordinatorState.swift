import CMUXAgentLaunch
import Foundation

/// What ``SessionPriorityCoordinator`` remembers about Claude panes between events, as pure
/// transitions.
///
/// A pane is restarted at most once per session and target (ruling R9). A target that does not
/// show up in the resumed session's recorded launch, or a resumed session that never reports
/// its start, leaves the pane not applied instead of restarting it at every turn end. A new
/// target or a new session in the pane allows one more restart.
///
/// An attempt that restarted nothing (held, refused) does not count, but parks the pane: it is
/// tried again for that target only when its own retry is due (its 30 s timer, its turn end).
struct SessionPriorityCoordinatorState: Equatable {
    /// How long a restarted pane waits for its resumed Claude's `SessionStart`.
    static let sessionStartTimeoutMs: Int64 = 60_000
    /// How long a held pane waits before it is tried again.
    static let heldRetrySeconds = 30

    /// A restart made for a session and target.
    struct Attempt: Equatable {
        var sessionId: String
        var target: SessionPriorityTarget
    }

    /// One Claude pane.
    struct PaneRecord: Equatable {
        /// The Claude session the record follows.
        var sessionId: String?
        var state: SessionPriorityPaneState = .upToDate
        /// Set from the start of a restart until its resumed Claude reports its start, at most
        /// ``SessionPriorityCoordinatorState/sessionStartTimeoutMs`` after the restart returned.
        var awaitingSessionStartUntilMs: Int64?
        /// A manual signal seen on the pane's screen during this session. It outlives the text.
        var stickyManual: SessionPriorityManualSignal?
        /// How the last restart attempt ended, e.g. `held.draft`. Never the resume command.
        var lastResultDescription: String?
        /// The last restart made, which is not made again for the same session and target.
        var lastAttempt: Attempt?
        /// The target of an attempt that was held or refused. The pane waits for its own retry
        /// (its timer or turn end) or another target before it is queued again.
        var parkedTarget: SessionPriorityTarget?
        /// `/effort` and `/model` results that were on screen when the user asked cmux to adjust
        /// the pane again. Only a result beyond them counts as a new manual change.
        var dismissedScreenMarkers = 0

        /// Ends an attempt that restarted nothing: the attempt is not spent, and the pane waits
        /// for its own retry.
        mutating func park() {
            parkedTarget = lastAttempt?.target
            lastAttempt = nil
            awaitingSessionStartUntilMs = nil
        }
    }

    /// Whether the coordinator tries a pane again on its own after a result.
    enum RetryPolicy: Equatable {
        case none
        case timer(seconds: Int)
    }

    var records: [UUID: PaneRecord] = [:]
    var queue = SessionPriorityApplyQueue()
    /// Workspaces that show the session priority row.
    var rowsShown: Set<UUID> = []

    /// Forgets every pane and queued restart. Returns the workspaces whose row to clear.
    mutating func disable() -> Set<UUID> {
        let clearRows = rowsShown
        records = [:]
        queue.removeAll()
        rowsShown = []
        return clearRows
    }

    /// Follows the session the pane runs now. Another session than the followed one starts a
    /// fresh record: its manual signal belonged to the old session. The last attempt stays,
    /// since it names its session.
    mutating func follow(panelId: UUID, sessionId: String) {
        var record = records[panelId] ?? PaneRecord()
        if let followed = record.sessionId, followed != sessionId, record.awaitingSessionStartUntilMs == nil {
            record = PaneRecord(lastAttempt: record.lastAttempt)
        }
        record.sessionId = sessionId
        records[panelId] = record
    }

    /// Whether the pane may be restarted for `target`: not when its last restart was for this
    /// session and target. Any other last attempt is forgotten, so a later return to it counts
    /// as a new target.
    mutating func shouldAttempt(panelId: UUID, sessionId: String, target: SessionPriorityTarget) -> Bool {
        guard let last = records[panelId]?.lastAttempt else { return true }
        guard last != Attempt(sessionId: sessionId, target: target) else { return false }
        records[panelId]?.lastAttempt = nil
        return true
    }

    /// A restart for `target` starts. Until its result the pane counts as restarting, so the
    /// replaced Claude's own session end does not drop it. The resumed Claude redraws the
    /// conversation, so the `/effort` and `/model` results it shows are not new.
    mutating func noteRestartStarted(panelId: UUID, sessionId: String, target: SessionPriorityTarget, nowMs: Int64) {
        var record = records[panelId] ?? PaneRecord()
        record.sessionId = sessionId
        record.state = .applying
        record.awaitingSessionStartUntilMs = nowMs + Self.sessionStartTimeoutMs
        record.lastAttempt = Attempt(sessionId: sessionId, target: target)
        record.dismissedScreenMarkers = .max
        records[panelId] = record
    }

    /// How a restart ended. Only a restart that replaced the pane's Claude spends the attempt.
    mutating func noteResult(panelId: UUID, _ result: SessionPriorityApplyResult, nowMs: Int64) -> RetryPolicy {
        var record = records[panelId] ?? PaneRecord()
        defer { records[panelId] = record }
        record.lastResultDescription = Self.describe(result)
        switch result {
        case .applied(let sessionId):
            // The restart resumed the session it confirmed, which may be fresher than the cache.
            record.sessionId = sessionId
            record.lastAttempt?.sessionId = sessionId
            record.state = .applying
            record.awaitingSessionStartUntilMs = nowMs + Self.sessionStartTimeoutMs
            return .none
        case .held(let reason):
            record.park()
            record.state = .held(reason)
            return .timer(seconds: Self.heldRetrySeconds)
        case .refused(let refusal):
            record.park()
            record.state = .notApplied(refusal)
            return .none
        case .respawnFailed:
            record.park()
            record.state = .notApplied(nil)
            return .none
        case .resumeNotTyped:
            // The pane was restarted and holds a bare shell; the user resumes it by hand.
            record.awaitingSessionStartUntilMs = nil
            record.state = .notApplied(nil)
            return .none
        }
    }

    /// The pane's own retry is due: its hold timer fired, or its Claude ended a turn.
    mutating func noteRetryDue(panelId: UUID) {
        records[panelId]?.parkedTarget = nil
    }

    /// A queued restart found its pane gone or no longer running Claude. The pane waits for
    /// its own retry, so a pane the drain cannot reach is not queued again at once.
    mutating func noteSkipped(panelId: UUID, target: SessionPriorityTarget) {
        guard var record = records[panelId] else { return }
        record.parkedTarget = target
        if record.state == .applying, record.awaitingSessionStartUntilMs == nil {
            record.state = .notApplied(nil)
            record.lastResultDescription = "paneUnavailable"
        }
        records[panelId] = record
    }

    /// The pane's Claude reported its start. Returns whether that ended the wait of a restart.
    @discardableResult
    mutating func noteSessionStarted(panelId: UUID, sessionId: String) -> Bool {
        guard let record = records[panelId], record.awaitingSessionStartUntilMs != nil,
              record.sessionId == sessionId else { return false }
        records[panelId]?.awaitingSessionStartUntilMs = nil
        return true
    }

    /// Whether the pane still waits for its restarted Claude's start. A wait past its deadline
    /// ends here and leaves the pane not applied.
    mutating func awaitsSessionStart(panelId: UUID, nowMs: Int64) -> Bool {
        guard let until = records[panelId]?.awaitingSessionStartUntilMs else { return false }
        guard nowMs >= until else { return true }
        records[panelId]?.awaitingSessionStartUntilMs = nil
        records[panelId]?.state = .notApplied(nil)
        records[panelId]?.lastResultDescription = "sessionStartTimedOut"
        return false
    }

    /// The pane's Claude session ended. A pane being restarted ignores it: that is the replaced
    /// Claude. Otherwise the record goes, with its manual signal; only the last attempt stays.
    mutating func noteSessionEnded(panelId: UUID) {
        guard let record = records[panelId], record.awaitingSessionStartUntilMs == nil else { return }
        records[panelId] = record.lastAttempt.map { PaneRecord(lastAttempt: $0) }
    }

    /// The user asked cmux to adjust these panes again: their manual signals from the screen
    /// are lifted, and the results still on screen no longer count.
    mutating func clearStickyManual(panelIds: [UUID]) {
        for panelId in panelIds where records[panelId] != nil {
            records[panelId]?.stickyManual = nil
            records[panelId]?.dismissedScreenMarkers = .max
        }
    }

    /// Whether the pane's screen, showing `markerCount` `/effort` or `/model` results, shows one
    /// the user did not dismiss. Results scrolling away lower the dismissed count.
    mutating func screenShowsManualMarker(panelId: UUID, markerCount: Int) -> Bool {
        let dismissed = records[panelId]?.dismissedScreenMarkers ?? 0
        if markerCount < dismissed { records[panelId]?.dismissedScreenMarkers = markerCount }
        return markerCount > dismissed
    }

    /// Records what a reconcile decided for the pane and returns the pane's state. A restart
    /// is queued unless it was already made for this session and target, or the pane was held
    /// or refused for this target and its own retry is not due yet.
    mutating func noteDecision(
        _ action: SessionPriorityPaneDecision.Action,
        panelId: UUID,
        workspaceId: UUID,
        sessionId: String
    ) -> SessionPriorityPaneState {
        if case .restart(let target) = action, shouldAttempt(panelId: panelId, sessionId: sessionId, target: target) {
            var record = records[panelId] ?? PaneRecord(sessionId: sessionId)
            // Held or refused for this target: wait for the pane's own retry.
            guard record.parkedTarget != target else { return record.state }
            record.parkedTarget = nil
            queue.enqueue(panelId: panelId, workspaceId: workspaceId, target: target)
            // A hold or refusal stays shown until the queued restart reports again.
            if record.state == .upToDate || Self.isManual(record.state) { record.state = .applying }
            records[panelId] = record
            return record.state
        }
        var record = records[panelId] ?? PaneRecord(sessionId: sessionId)
        defer { records[panelId] = record }
        switch action {
        case .leave(.awaitingRestart):
            return record.state
        case .leave(.manual(let signal)):
            if signal == .userCommandOnScreen { record.stickyManual = signal }
            record.state = .manual(signal)
        case .leave(.noTarget), .leave(.nothingToApply), .leave(.upToDate):
            record.state = .upToDate
        case .restart:
            // Already restarted for this session and target, and it did not land (R9).
            if record.lastResultDescription == Self.describe(.applied(sessionID: sessionId)) {
                record.lastResultDescription = "targetNotRecorded"
            }
            record.state = .notApplied(nil)
        }
        queue.remove(panelId: panelId)
        record.awaitingSessionStartUntilMs = nil
        record.parkedTarget = nil
        return record.state
    }

    /// Forgets panes that no longer exist.
    mutating func retainPanes(_ panelIds: Set<UUID>) {
        records = records.filter { panelIds.contains($0.key) }
    }

    /// How many `/effort` and `/model` results `text` shows.
    static func screenMarkerCount(in text: String) -> Int {
        SessionPriorityManualSignals.screenMarkers.reduce(0) { count, marker in
            count + text.components(separatedBy: marker).count - 1
        }
    }

    /// A short stable name for a result, for the status detail. It never holds the command.
    static func describe(_ result: SessionPriorityApplyResult) -> String {
        switch result {
        case .applied: return "applied"
        case .held(let reason): return "held.\(reason.rawValue)"
        case .refused(let refusal): return "refused.\(refusal.rawValue)"
        case .respawnFailed: return "respawnFailed"
        case .resumeNotTyped(let manual):
            switch manual.reason {
            case .paneReplaced: return "resumeNotTyped.paneReplaced"
            case .notTyped: return "resumeNotTyped.notTyped"
            case .previousClaudeStillRunning: return "resumeNotTyped.previousClaudeStillRunning"
            }
        }
    }

    private static func isManual(_ state: SessionPriorityPaneState) -> Bool {
        if case .manual = state { return true }
        return false
    }
}
