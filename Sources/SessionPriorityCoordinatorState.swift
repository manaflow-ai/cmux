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
    /// How long after its resumed Claude's start a restarted pane still counts as a Claude pane
    /// while the agent index does not show it.
    static let indexAfterSessionStartTimeoutMs: Int64 = 60_000
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
        /// Set when a restart replaced the pane's Claude, until a reconcile after its resumed
        /// Claude's start finds it in the agent index, or its session ends. Meanwhile, for at
        /// most ``SessionPriorityCoordinatorState/indexAfterSessionStartTimeoutMs`` after that
        /// start, the pane still counts as a Claude pane, so its workspace keeps its place in
        /// the plan.
        var awaitsIndexAfterRestart = false
        /// When the restarted Claude reported its start (the hook's own time). A `SessionEnd`
        /// from before it is the replaced Claude's, which shares the session id.
        var sessionStartedAtMs: Int64?
        /// A manual signal seen on the pane's screen during this session. It outlives the text.
        var stickyManual: SessionPriorityManualSignal?
        /// How the last restart attempt ended, e.g. `held.draft`. Never the resume command.
        /// Cleared when the pane becomes manual, so its status shows the manual signal instead.
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
            awaitsIndexAfterRestart = false
        }
    }

    /// Whether the coordinator tries a pane again on its own after a result.
    enum RetryPolicy: Equatable {
        case none
        case timer(seconds: Int)
    }

    /// How long triggers settle before the reconcile pass that may queue restarts runs.
    static let reconcileDebounceMs: Int64 = 2_000

    var records: [UUID: PaneRecord] = [:]
    var queue = SessionPriorityApplyQueue()
    /// Workspaces that show the session priority row.
    var rowsShown: Set<UUID> = []
    /// When the one reconcile pass that may queue restarts is due; `nil` when none is pending.
    private(set) var reconcileDueAtMs: Int64?
    /// When each pane's Claude last ended a turn, where the restart gate's quiet window starts.
    /// Kept while off, so turning the feature on right after a turn end still waits.
    private(set) var lastTurnEndedAtMs: [UUID: Int64] = [:]
    /// Panes whose Claude ended its last turn with background work still running (the turn end
    /// or idle prompt reported `pending_work`), until its next turn starts, a turn end or idle
    /// prompt without it, or its session ends. Later hooks such as a `SubagentStop` do not end
    /// it. Kept while off.
    private(set) var backgroundWorkPanelIds: Set<UUID> = []
    /// When cmux last set aside the user's own `/effort` and `/model` on each pane: its last
    /// restart of the pane, or "Adjust Claude Effort Automatically" on its workspace. Only a
    /// change the transcript records later counts. Kept while off.
    private(set) var manualDismissedAtMs: [UUID: Int64] = [:]

    /// Whether the coordinator shows rows or holds pane records, queued restarts or a pending
    /// pass: what ``disable()`` drops. The turn ends, background work and dismissal times kept
    /// while off do not count.
    var hasActiveState: Bool {
        !rowsShown.isEmpty || !records.isEmpty || !queue.isEmpty || reconcileDueAtMs != nil
    }

    /// Forgets every pane record, queued restart and pending pass. Returns the workspaces whose
    /// row to clear.
    mutating func disable() -> Set<UUID> {
        let clearRows = rowsShown
        records = [:]
        queue.removeAll()
        rowsShown = []
        reconcileDueAtMs = nil
        return clearRows
    }

    /// Asks for the reconcile pass and returns when it is due. A trigger that `settles` (a user
    /// move or a settings change) moves the pass to ``reconcileDebounceMs`` from now, so the
    /// gesture settles first; any other trigger joins a pending pass, or asks for one that far
    /// out.
    @discardableResult
    mutating func requestReconcile(nowMs: Int64, settles: Bool) -> Int64 {
        if let due = reconcileDueAtMs, !settles { return due }
        let due = max(reconcileDueAtMs ?? .min, nowMs + Self.reconcileDebounceMs)
        reconcileDueAtMs = due
        return due
    }

    /// Whether the pending pass is due at `nowMs`. A due pass is taken: it runs once.
    mutating func takeReconcileDue(nowMs: Int64) -> Bool {
        guard let due = reconcileDueAtMs, nowMs >= due else { return false }
        reconcileDueAtMs = nil
        return true
    }

    /// The pane's Claude ended a turn, or showed its idle prompt, at `nowMs`, with or without
    /// background work still running.
    mutating func noteTurnEnded(panelId: UUID, nowMs: Int64, pendingWork: Bool = false) {
        lastTurnEndedAtMs[panelId] = nowMs
        if pendingWork {
            backgroundWorkPanelIds.insert(panelId)
        } else {
            backgroundWorkPanelIds.remove(panelId)
        }
    }

    /// The pane's Claude started a turn: background work its last turn end reported no longer
    /// holds the pane; the running turn does.
    mutating func noteTurnStarted(panelId: UUID) {
        backgroundWorkPanelIds.remove(panelId)
    }

    /// Whether the pane's Claude ended its last turn with background work still running.
    func hasPendingBackgroundWork(panelId: UUID) -> Bool {
        backgroundWorkPanelIds.contains(panelId)
    }

    /// The transcript records a `/effort` or `/model` the user ran after the pane's dismissal
    /// time: the pane is left alone for the session, like a result seen on screen. The restart
    /// that found it was not made, so its attempt is not spent.
    mutating func noteManualChangeInTranscript(panelId: UUID) {
        var record = records[panelId] ?? PaneRecord()
        record.lastAttempt = nil
        record.parkedTarget = nil
        record.awaitingSessionStartUntilMs = nil
        record.stickyManual = .userCommandOnScreen
        record.state = .manual(.userCommandOnScreen)
        record.lastResultDescription = nil
        records[panelId] = record
    }

    /// Follows the session the agent index shows in the pane. Another session than the followed
    /// one starts a fresh record: its manual signal belonged to the old session. The last attempt
    /// stays, since it names its session. Seen after a restarted Claude reported its start, the
    /// entry is the resumed Claude's, so the restart no longer needs to count the pane.
    mutating func follow(panelId: UUID, sessionId: String) {
        var record = records[panelId] ?? PaneRecord()
        if let followed = record.sessionId, followed != sessionId, record.awaitingSessionStartUntilMs == nil {
            record = PaneRecord(lastAttempt: record.lastAttempt)
        }
        record.sessionId = sessionId
        if record.awaitingSessionStartUntilMs == nil { record.awaitsIndexAfterRestart = false }
        records[panelId] = record
    }

    /// Whether a restart is moving the pane to a new Claude, which the agent index may not show
    /// yet: from the restart until its resumed Claude reports its start and then shows in the
    /// index, its session ends, or ``indexAfterSessionStartTimeoutMs`` passes after that start
    /// (a Claude that died unseen). Such a pane still counts as one of its workspace's Claude
    /// panes; past the limit it counts only by its index entry.
    func isRestarting(panelId: UUID, nowMs: Int64) -> Bool {
        guard let record = records[panelId] else { return false }
        if record.awaitingSessionStartUntilMs != nil { return true }
        guard record.awaitsIndexAfterRestart, record.sessionId != nil else { return false }
        guard let started = record.sessionStartedAtMs else { return true }
        return nowMs < started + Self.indexAfterSessionStartTimeoutMs
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
    /// replaced Claude's own session end does not drop it.
    mutating func noteRestartStarted(panelId: UUID, sessionId: String, target: SessionPriorityTarget, nowMs: Int64) {
        var record = records[panelId] ?? PaneRecord()
        record.sessionId = sessionId
        record.state = .applying
        record.awaitingSessionStartUntilMs = nowMs + Self.sessionStartTimeoutMs
        record.lastAttempt = Attempt(sessionId: sessionId, target: target)
        records[panelId] = record
    }

    /// How a restart ended. Only a restart that replaced the pane's Claude spends the attempt,
    /// and only then are the `/effort` and `/model` results on screen not new: the resumed
    /// Claude redraws the conversation. One the user typed before a hold or refusal still counts.
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
            record.awaitsIndexAfterRestart = true
            record.dismissedScreenMarkers = .max
            manualDismissedAtMs[panelId] = nowMs
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
            record.awaitsIndexAfterRestart = false
            record.dismissedScreenMarkers = .max
            manualDismissedAtMs[panelId] = nowMs
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

    /// The pane's Claude reported its start at `occurredAtMs` (the hook's time; `nil` when
    /// unknown). Returns whether that ended the wait of a restart.
    @discardableResult
    mutating func noteSessionStarted(panelId: UUID, sessionId: String, occurredAtMs: Int64? = nil) -> Bool {
        guard let record = records[panelId], record.awaitingSessionStartUntilMs != nil,
              record.sessionId == sessionId else { return false }
        records[panelId]?.awaitingSessionStartUntilMs = nil
        records[panelId]?.sessionStartedAtMs = occurredAtMs
        return true
    }

    /// Whether the pane still waits for its restarted Claude's start. A wait past its deadline
    /// ends here and leaves the pane not applied, counted as a Claude pane only once the agent
    /// index shows one in it.
    mutating func awaitsSessionStart(panelId: UUID, nowMs: Int64) -> Bool {
        guard let until = records[panelId]?.awaitingSessionStartUntilMs else { return false }
        guard nowMs >= until else { return true }
        records[panelId]?.awaitingSessionStartUntilMs = nil
        records[panelId]?.awaitsIndexAfterRestart = false
        records[panelId]?.state = .notApplied(nil)
        records[panelId]?.lastResultDescription = "sessionStartTimedOut"
        return false
    }

    /// The pane's Claude session ended at `occurredAtMs` (the hook's time; `nil` when unknown),
    /// and with it any background work it reported. An end from before the restarted Claude's
    /// start, or one while a restart waits for that start, is the replaced Claude's: the record
    /// stays. Otherwise the record goes, with its manual signal; only the last attempt stays.
    mutating func noteSessionEnded(panelId: UUID, occurredAtMs: Int64? = nil) {
        if let occurredAtMs, let started = records[panelId]?.sessionStartedAtMs, occurredAtMs < started {
            return
        }
        backgroundWorkPanelIds.remove(panelId)
        guard let record = records[panelId], record.awaitingSessionStartUntilMs == nil else { return }
        records[panelId] = record.lastAttempt.map { PaneRecord(lastAttempt: $0) }
    }

    /// The user asked cmux to adjust these panes again at `nowMs`: their manual signals from the
    /// screen are lifted, and the results still on screen or in the transcript no longer count.
    mutating func clearStickyManual(panelIds: [UUID], nowMs: Int64) {
        for panelId in panelIds {
            manualDismissedAtMs[panelId] = nowMs
            guard records[panelId] != nil else { continue }
            records[panelId]?.stickyManual = nil
            records[panelId]?.dismissedScreenMarkers = .max
        }
    }

    /// Whether the pane's screen, showing `markerCount` `/effort` or `/model` results, shows one
    /// the user did not dismiss. Results scrolling away lower the dismissed count.
    mutating func screenShowsManualMarker(panelId: UUID, markerCount: Int) -> Bool {
        let shows = showsUndismissedManualMarker(panelId: panelId, markerCount: markerCount)
        if let dismissed = records[panelId]?.dismissedScreenMarkers, markerCount < dismissed {
            records[panelId]?.dismissedScreenMarkers = markerCount
        }
        return shows
    }

    /// ``screenShowsManualMarker(panelId:markerCount:)`` without lowering the dismissed count,
    /// for the restart gate's last look at a queued pane.
    func showsUndismissedManualMarker(panelId: UUID, markerCount: Int) -> Bool {
        markerCount > (records[panelId]?.dismissedScreenMarkers ?? 0)
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
            // The pane is left alone now: an earlier hold or refusal no longer describes it.
            record.lastResultDescription = nil
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
        lastTurnEndedAtMs = lastTurnEndedAtMs.filter { panelIds.contains($0.key) }
        backgroundWorkPanelIds.formIntersection(panelIds)
        manualDismissedAtMs = manualDismissedAtMs.filter { panelIds.contains($0.key) }
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
