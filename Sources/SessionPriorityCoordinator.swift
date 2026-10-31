import CMUXAgentLaunch
import CmuxAgentJournal
import CmuxFoundation
import CmuxSettings
import Foundation

/// Gives each Claude pane the effort its workspace's priority asks for, while
/// `automation.sessionPriority.enabled` is on.
///
/// The decisions are pure: ``SessionPriorityPlan`` ranks each window's Claude workspaces,
/// ``SessionPriorityManualSignals`` and ``SessionPriorityPaneDecision`` decide each pane, and
/// ``SessionPriorityCoordinatorState`` remembers what was tried. This type reads the live app,
/// keeps each workspace's sidebar row current, and restarts one pane at a time, app-wide,
/// between turns through ``Workspace/applySessionPriority(panelId:target:paneIsFree:)``. Off, it
/// types nothing and shows no row.
///
/// Every trigger asks for one debounced reconcile pass, 2 s out (ruling R18): it is the only
/// path that queues restarts, so a pass never runs against a rank the user is still moving.
@MainActor
final class SessionPriorityCoordinator {
    static let shared = SessionPriorityCoordinator()

    /// The settings the coordinator acts on.
    struct Settings: Equatable {
        var enabled: Bool
        var urgentCount: Int
        var matrix: String

        static func current() -> Settings {
            let section = AutomationCatalogSection()
            return Settings(
                enabled: section.sessionPriority.value(in: .standard),
                urgentCount: section.sessionPriorityUrgentCount.value(in: .standard),
                matrix: section.sessionPriorityMatrix.value(in: .standard)
            )
        }
    }

    /// A pane cmux sees a Claude session in, or one a session priority restart is moving to a
    /// new Claude.
    struct ClaudePane {
        var panelId: UUID
        var snapshot: SessionRestorableAgentSnapshot?
    }

    private(set) var state = SessionPriorityCoordinatorState()
    private var lastSettings: Settings?
    private var defaultsObserver: (any NSObjectProtocol)?
    /// Waits for the pending reconcile pass (``SessionPriorityCoordinatorState/reconcileDueAtMs``).
    private var reconcileTask: Task<Void, Never>?
    private var drainTask: Task<Void, Never>?
    /// At most one per pane: a held pane's retry, or a restarted pane's session-start deadline.
    private var paneTimers: [UUID: Task<Void, Never>] = [:]

    var isEnabled: Bool {
        AutomationCatalogSection().sessionPriority.value(in: .standard)
    }

    /// Whether session priority is on, for a trigger or a status read. Finding it off while rows,
    /// pane records, queued restarts or a pending pass remain means it went off without a
    /// notification this process saw (a `defaults write` from another process), so the disable
    /// path runs first.
    private func isEnabledDroppingStaleState() -> Bool {
        guard !isEnabled else { return true }
        if state.hasActiveState {
            lastSettings = .current()
            disable()
        }
        return false
    }

    /// Plugs into the workspace hooks and the settings. Later calls do nothing.
    func start() {
        guard defaultsObserver == nil else { return }
        SessionPriorityCoordinatorHook.userDidReorder = { [weak self] tabManager in
            self?.userDidReorder(tabManager: tabManager)
        }
        SessionPriorityCoordinatorHook.workspaceStateDidChange = { [weak self] workspaceId in
            self?.workspaceStateDidChange(workspaceId: workspaceId)
        }
        SessionPriorityCoordinatorHook.adjustAutomaticallyRequested = { [weak self] workspaceId in
            self?.adjustAutomatically(workspaceId: workspaceId)
        }
        lastSettings = .current()
        defaultsObserver = NotificationCenter.default.addUserDefaultsObserver { [weak self] in
            self?.settingsDidChange()
        }
        // Restore drops every status row, so while on the rows are built once the restored
        // windows settle; while off there is nothing to show or remove.
        if lastSettings?.enabled == true { requestReconcile(settles: true) }
    }

    // MARK: - Triggers

    /// Observes one live journal event. Cheap: each trigger only asks for the debounced pass.
    func observe(_ draft: AgentJournalEventDraft) {
        guard draft.source == "claude", !draft.isSubagent, draft.unattributedReason == nil,
              let panelId = draft.surfaceId.flatMap(UUID.init(uuidString:)) else { return }
        switch draft.kind {
        case .turnStarted:
            state.noteTurnStarted(panelId: panelId)
        case .turnCompleted, .idleObserved:
            // The quiet window and a background-work hold run from here, also for a turn end seen
            // while off.
            state.noteTurnEnded(panelId: panelId, nowMs: Self.nowMs(), pendingWork: draft.pendingWork)
            guard isEnabledDroppingStaleState() else { return }
            // Between turns: a pane held or refused earlier may be tried again.
            state.noteRetryDue(panelId: panelId)
            requestReconcile()
        case .sessionStarted:
            guard let sessionId = draft.sessionId,
                  state.noteSessionStarted(panelId: panelId, sessionId: sessionId, occurredAtMs: draft.occurredAtMs)
            else { return }
            log("sessionPriority panel=\(panelId.uuidString.prefix(5)) sessionStarted")
            // The pass refreshes the agent index first, so it reads the launch this recorded. If
            // the index still lacks the pane when its wait ends, a pass then drops it from the plan.
            let waitEndsInMs = draft.occurredAtMs + SessionPriorityCoordinatorState.indexAfterSessionStartTimeoutMs
                - Self.nowMs()
            armTimer(panelId: panelId, after: .milliseconds(max(waitEndsInMs, 0) + 500))
            requestReconcile()
        case .sessionEnded:
            let hadRecord = state.records[panelId] != nil
            state.noteSessionEnded(panelId: panelId, occurredAtMs: draft.occurredAtMs)
            guard hadRecord else { return }
            requestReconcile()
        default:
            return
        }
    }

    /// A user move in `tabManager`'s sidebar, possibly one that left the order as it was.
    func userDidReorder(tabManager: TabManager) {
        guard isEnabledDroppingStaleState() else { return }
        requestReconcile(settles: true)
    }

    /// A workspace's difficulty or manual flag changed.
    func workspaceStateDidChange(workspaceId: UUID) {
        guard isEnabledDroppingStaleState() else { return }
        requestReconcile()
    }

    /// Re-reads the settings and acts only when one of them changed: turning the feature off
    /// stops everything now, any other change reconsiders the panes after the debounce.
    func settingsDidChange() {
        let settings = Settings.current()
        guard settings != lastSettings else { return }
        let wasEnabled = lastSettings?.enabled ?? false
        lastSettings = settings
        if settings.enabled {
            requestReconcile(settles: true)
        } else if wasEnabled {
            disable()
        }
    }

    /// "Adjust automatically": the workspace's panes lose the manual signals seen on screen, and
    /// a `/effort` or `/model` the transcript recorded until now no longer counts.
    private func adjustAutomatically(workspaceId: UUID) {
        guard isEnabledDroppingStaleState(),
              let workspace = AppDelegate.shared?.tabManagerFor(tabId: workspaceId)?.workspacesById[workspaceId]
        else { return }
        state.clearStickyManual(panelIds: workspace.orderedPanelIds, nowMs: Self.nowMs())
        requestReconcile()
    }

    private func disable() {
        reconcileTask?.cancel()
        reconcileTask = nil
        for timer in paneTimers.values { timer.cancel() }
        paneTimers = [:]
        let cleared = state.disable()
        removeRows(also: cleared)
        log("sessionPriority disabled rows=\(cleared.count)")
    }

    // MARK: - Scheduling

    /// Asks for the one reconcile pass that may queue restarts (ruling R18). A user move or a
    /// settings change (`settles`) moves it to 2 s from now; any other trigger joins the pending
    /// pass, or asks for one 2 s out.
    private func requestReconcile(settles: Bool = false) {
        state.requestReconcile(nowMs: Self.nowMs(), settles: settles)
        guard reconcileTask == nil else { return }
        reconcileTask = Task { [weak self] in
            await self?.reconcileWhenDue()
        }
    }

    /// Runs the pending pass once it is due, then any pass asked for meanwhile.
    private func reconcileWhenDue() async {
        while let due = state.reconcileDueAtMs {
            let wait = due - Self.nowMs()
            if wait > 0 {
                try? await Task.sleep(for: .milliseconds(wait))
                guard !Task.isCancelled else { return }
                // Read the due time again: a user move may have pushed it back.
                continue
            }
            // Decide from the launches recorded by now; at start-up the cache may be empty.
            if isEnabled { _ = await SharedLiveAgentIndex.shared.indexRefreshingNow() }
            guard !Task.isCancelled else { return }
            // A user move during the refresh pushed the pass back.
            guard state.takeReconcileDue(nowMs: Self.nowMs()) else { continue }
            reconcile()
        }
        reconcileTask = nil
    }

    /// Replaces the pane's timer with one that makes the pane's retry due and asks for the pass
    /// after `delay`.
    private func armTimer(panelId: UUID, after delay: Duration) {
        paneTimers[panelId]?.cancel()
        paneTimers[panelId] = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.paneTimers[panelId] = nil
            self.state.noteRetryDue(panelId: panelId)
            self.requestReconcile()
        }
    }

    private func cancelTimer(panelId: UUID) {
        paneTimers.removeValue(forKey: panelId)?.cancel()
    }

    // MARK: - Reconcile

    /// Brings every window's rows and queued restarts in line with the settings and the panes.
    /// Off (turned off while a pass was pending), it only drops what is left.
    private func reconcile() {
        guard isEnabledDroppingStaleState() else {
            removeRows(also: [])
            return
        }
        let settings = Settings.current()
        let matrix = SessionPriorityMatrix.fromStoredString(settings.matrix)
        let nowMs = Self.nowMs()
        var existingPanelIds = Set<UUID>()
        var shownRows = Set<UUID>()
        for tabManager in Self.tabManagers() {
            let panes = claudePanes(in: tabManager)
            let plan = Self.plan(for: tabManager, panes: panes, urgentCount: settings.urgentCount, matrix: matrix)
            for workspace in tabManager.tabs {
                existingPanelIds.formUnion(workspace.panels.keys)
                guard let entry = plan[workspace.id] else {
                    Self.removeRow(from: workspace)
                    continue
                }
                let paneStates = (panes[workspace.id] ?? []).map {
                    reconcilePane($0, in: workspace, entry: entry, nowMs: nowMs)
                }
                Self.showRow(
                    SessionPriorityStatusRow.entry(
                        tier: entry.tier,
                        difficulty: entry.difficulty,
                        difficultySource: entry.difficultySource,
                        target: entry.target,
                        paneStates: paneStates
                    ),
                    in: workspace
                )
                shownRows.insert(workspace.id)
            }
        }
        state.retainPanes(existingPanelIds)
        for panelId in paneTimers.keys where !existingPanelIds.contains(panelId) {
            cancelTimer(panelId: panelId)
        }
        state.rowsShown = shownRows
        startDrainIfNeeded()
    }

    /// Decides one pane and returns its state; a restart it needs is queued.
    private func reconcilePane(
        _ pane: ClaudePane,
        in workspace: Workspace,
        entry: SessionPriorityPlan.Entry,
        nowMs: Int64
    ) -> SessionPriorityPaneState {
        let panelId = pane.panelId
        // A restart in progress owns the pane until it returns.
        if Workspace.isSessionPriorityApplyInFlight(panelId: panelId) { return .applying }
        let awaiting = state.awaitsSessionStart(panelId: panelId, nowMs: nowMs)
        guard let snapshot = pane.snapshot else { return state.records[panelId]?.state ?? .applying }
        state.follow(panelId: panelId, sessionId: snapshot.sessionId)
        let arguments = snapshot.launchCommand?.arguments ?? []
        let launchEnvironment = snapshot.launchCommand?.environment ?? [:]
        let manualSignal = SessionPriorityManualSignals.detect(
            userFlag: workspace.sessionPriorityState.isManual,
            launchArguments: arguments,
            launchEnvironment: launchEnvironment,
            workspaceEnvironment: workspace.workspaceEnvironment,
            screenText: nil
        )
        var action = SessionPriorityPaneDecision.decide(
            target: entry.target,
            manualSignal: manualSignal,
            stickyManual: state.records[panelId]?.stickyManual,
            // Only a level cmux marked as its own is current; any other makes the pane manual.
            currentEffort: ClaudeEffortLevel(rawValue: launchEnvironment[ClaudeEffortLevel.environmentKey] ?? ""),
            currentModel: SessionPriorityLaunchArguments.value(ofOption: "--model", in: arguments),
            awaitingSessionStart: awaiting
        )
        // The screen is read only for a pane about to be queued; the transcript is probed right
        // before its restart. A pane being restarted shows the restart, not the user, and is
        // never queued here.
        if case .restart = action, screenShowsUndismissedManualChange(panelId: panelId, in: workspace) {
            action = .leave(.manual(.userCommandOnScreen))
        }
        let paneState = state.noteDecision(action, panelId: panelId, workspaceId: workspace.id, sessionId: snapshot.sessionId)
        switch paneState {
        case .held, .applying:
            break
        case .upToDate, .notApplied, .manual:
            cancelTimer(panelId: panelId)
        }
        return paneState
    }

    /// Whether the pane's screen shows a `/effort` or `/model` result the user did not dismiss.
    /// Asked only for a pane about to be queued, which has no sticky signal in a workspace not
    /// marked manual; a result found becomes sticky for the session.
    private func screenShowsUndismissedManualChange(panelId: UUID, in workspace: Workspace) -> Bool {
        guard let text = workspace.terminalPanel(for: panelId)?.surface.visibleText() else { return false }
        let markers = SessionPriorityCoordinatorState.screenMarkerCount(in: text)
        return state.screenShowsManualMarker(panelId: panelId, markerCount: markers)
    }

    // MARK: - Restarts

    /// Starts the one task that restarts queued panes, unless it runs already.
    private func startDrainIfNeeded() {
        guard drainTask == nil, !state.queue.isEmpty else { return }
        drainTask = Task { [weak self] in
            while let self, let entry = self.nextEntryToApply() {
                await self.apply(entry)
            }
            self?.drainTask = nil
        }
    }

    private func nextEntryToApply() -> SessionPriorityApplyQueue.Entry? {
        guard isEnabledDroppingStaleState() else {
            state.queue.removeAll()
            return nil
        }
        return state.queue.next()
    }

    /// Restarts one queued pane, wherever it is now, and records how that ended.
    private func apply(_ entry: SessionPriorityApplyQueue.Entry) async {
        let panelId = entry.panelId
        guard let workspace = AppDelegate.shared?.workspaceContainingPanel(
            panelId: panelId,
            preferredWorkspaceId: entry.workspaceId
        )?.workspace,
            let sessionId = workspace.sessionPriorityClaudeSnapshot(panelId: panelId)?.sessionId,
            state.shouldAttempt(panelId: panelId, sessionId: sessionId, target: entry.target)
        else {
            state.noteSkipped(panelId: panelId, target: entry.target)
            requestReconcile()
            return
        }
        state.noteRestartStarted(panelId: panelId, sessionId: sessionId, target: entry.target, nowMs: Self.nowMs())
        cancelTimer(panelId: panelId)
        requestReconcile()
        let paneIsFree: @MainActor () -> SessionPriorityApplyGate.Verdict = { [weak self, weak workspace] in
            guard let self, let workspace else { return .hold(.unknownScreen) }
            return self.paneVerdict(panelId: panelId, workspace: workspace, target: entry.target)
        }
        // The cheap synchronous gate first, so a held pane's retry reads no transcript.
        let result: SessionPriorityApplyResult
        if case .hold(let reason) = paneIsFree() {
            result = .held(reason)
        } else if await userChangedEffortInTranscript(panelId: panelId, workspace: workspace) {
            guard isEnabledDroppingStaleState() else { return }
            state.noteManualChangeInTranscript(panelId: panelId)
            log("sessionPriority panel=\(panelId.uuidString.prefix(5)) manual.transcript")
            requestReconcile()
            return
        } else {
            log("sessionPriority panel=\(panelId.uuidString.prefix(5)) restart effort=\(entry.target.effort?.rawValue ?? "-")")
            result = await workspace.applySessionPriority(panelId: panelId, target: entry.target, paneIsFree: paneIsFree)
        }
        // The pane restarted to a bare shell: the user needs the command, setting or not.
        if case .resumeNotTyped(let manual) = result {
            SessionPriorityNotice.notRestarted(target: entry.target, manual: manual)
                .post(workspaceId: workspace.id, panelId: panelId)
        }
        // Turned off meanwhile: `disable()` dropped, or drops now, the pane and its row.
        guard isEnabledDroppingStaleState() else { return }
        let nowMs = Self.nowMs()
        if case .timer(let seconds) = state.noteResult(panelId: panelId, result, nowMs: nowMs) {
            armTimer(panelId: panelId, after: .seconds(seconds))
        }
        if let until = state.records[panelId]?.awaitingSessionStartUntilMs {
            // Past the deadline the next reconcile marks the pane not applied.
            armTimer(panelId: panelId, after: .milliseconds(until - nowMs + 500))
        }
        log("sessionPriority panel=\(panelId.uuidString.prefix(5)) result=\(SessionPriorityCoordinatorState.describe(result))")
        requestReconcile()
    }

    // MARK: - Status

    /// The workspace's session priority now, for `session_priority.get` and `.set`.
    func snapshot(for workspace: Workspace) -> SessionPrioritySnapshot {
        guard isEnabledDroppingStaleState(), let tabManager = AppDelegate.shared?.tabManagerFor(tabId: workspace.id) else {
            return makeSnapshot(workspace, panes: claudePanes(in: workspace), entry: nil, enabled: false)
        }
        let panes = claudePanes(in: tabManager)
        let settings = Settings.current()
        let plan = Self.plan(
            for: tabManager,
            panes: panes,
            urgentCount: settings.urgentCount,
            matrix: .fromStoredString(settings.matrix)
        )
        return makeSnapshot(workspace, panes: panes[workspace.id] ?? [], entry: plan[workspace.id], enabled: true)
    }

    /// The window's workspaces that have a Claude pane or are marked manual, in priority order,
    /// for `session_priority.status`.
    func statusSnapshot(tabManager: TabManager) -> [SessionPrioritySnapshot] {
        let enabled = isEnabledDroppingStaleState()
        let panes = claudePanes(in: tabManager)
        let settings = Settings.current()
        let plan = enabled
            ? Self.plan(for: tabManager, panes: panes, urgentCount: settings.urgentCount, matrix: .fromStoredString(settings.matrix))
            : [:]
        return tabManager.sessionPriorityEffectiveOrder.compactMap { workspaceId in
            guard let workspace = tabManager.workspacesById[workspaceId] else { return nil }
            let workspacePanes = panes[workspaceId] ?? []
            guard !workspacePanes.isEmpty || workspace.sessionPriorityState.isManual else { return nil }
            return makeSnapshot(workspace, panes: workspacePanes, entry: plan[workspaceId], enabled: enabled)
        }
    }

    private func makeSnapshot(
        _ workspace: Workspace,
        panes: [ClaudePane],
        entry: SessionPriorityPlan.Entry?,
        enabled: Bool
    ) -> SessionPrioritySnapshot {
        let paneSnapshots: [SessionPrioritySnapshot.Pane] = enabled ? panes.map { pane in
            let record = state.records[pane.panelId]
            return SessionPrioritySnapshot.Pane(
                surfaceId: pane.panelId,
                sessionId: pane.snapshot?.sessionId ?? record?.sessionId,
                currentEffort: ClaudeEffortLevel(rawValue: pane.snapshot?.launchCommand?.environment?["CLAUDE_CODE_EFFORT_LEVEL"] ?? ""),
                state: Workspace.isSessionPriorityApplyInFlight(panelId: pane.panelId) ? .applying : record?.state ?? .upToDate,
                detail: record?.lastResultDescription
            )
        } : []
        return SessionPrioritySnapshot(
            workspaceId: workspace.id,
            priority: workspace.sessionPriorityState,
            entry: entry,
            panes: paneSnapshots,
            enabled: enabled
        )
    }

    static func nowMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }

    func log(_ message: @autoclosure () -> String) {
#if DEBUG
        cmuxDebugLog(message())
#endif
    }
}
