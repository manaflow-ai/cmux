import CmuxAgentJournal
import CmuxSidebar
import Foundation

/// Settles a Claude pane whose background work ended while the agent sat idle.
///
/// Claude reports background work only in its `Stop` payload. When a
/// `run_in_background` command ends and no later turn runs, no hook arrives to
/// say so, and the pane stayed `backgroundWorkPending` for good: the sidebar
/// kept showing Waiting and hibernation refused the agent as busy.
/// https://github.com/manaflow-ai/cmux/issues/26358
///
/// A periodic check reads the transcript (task notifications) and, for Bash
/// and Monitor work, the process scope (no live shell under the agent). When
/// both say the work is gone, it journals the turn completion the agent never
/// sent. The event carries the time of the check, so a turn that started
/// after it wins in the reducer and the reconciler.
extension AgentHibernationController {
    func startBackgroundWorkDrainTimer() {
        guard backgroundWorkDrainTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        let interval = ClaudeBackgroundWorkDrain.checkIntervalSeconds
        timer.schedule(deadline: .now() + .seconds(interval), repeating: .seconds(interval))
        timer.setEventHandler {
            Task { @MainActor in
                await AgentHibernationController.shared.settleDrainedBackgroundWork()
            }
        }
        timer.resume()
        backgroundWorkDrainTimer = timer
    }

    func stopBackgroundWorkDrainTimer() {
        backgroundWorkDrainTimer?.cancel()
        backgroundWorkDrainTimer = nil
    }

    /// One check over every Claude pane still waiting on background work.
    func settleDrainedBackgroundWork(now: Date = Date()) async {
        guard !backgroundWorkDrainCheckInFlight,
              AgentHibernationTrackingGate.isEnabled(),
              let appDelegate = AppDelegate.shared else { return }
        // The cached index is enough to see whether any pane qualifies; only
        // then pay for a fresh process scan.
        guard let cachedIndex = SharedLiveAgentIndex.shared.index else { return }
        let cachedCandidates = backgroundWorkDrainCandidates(appDelegate: appDelegate, index: cachedIndex, now: now)
        guard !cachedCandidates.isEmpty else {
            backgroundWorkDrainRejections.removeAll()
            backgroundWorkDrainsJournaled.removeAll()
            return
        }
        backgroundWorkDrainCheckInFlight = true
        defer { backgroundWorkDrainCheckInFlight = false }
        // A pane parked on a cron never settles here; skip the scan for it.
        let sessionIds = Set(cachedCandidates.map(\.agent.sessionId))
        let settleableSessions = await Task.detached(priority: .utility) {
            ClaudeBackgroundWorkDrain.sessionsWithoutCrons(sessionIds)
        }.value
        guard !settleableSessions.isEmpty,
              let index = await SharedLiveAgentIndex.shared.indexRefreshingNow(),
              AgentHibernationTrackingGate.isEnabled() else { return }
        let checkedAt = Date()
        // One drain per pending episode: if the journal did not admit it, a
        // second one would not be admitted either.
        let candidates = backgroundWorkDrainCandidates(appDelegate: appDelegate, index: index, now: checkedAt)
            .filter { candidate in
                settleableSessions.contains(candidate.agent.sessionId)
                    && backgroundWorkDrainsJournaled[candidate.key] != .some(candidate.lifecycleChangedAt)
            }
        let candidateKeys = Set(candidates.map(\.key))
        backgroundWorkDrainRejections = backgroundWorkDrainRejections.filter { candidateKeys.contains($0.key) }
        backgroundWorkDrainsJournaled = backgroundWorkDrainsJournaled.filter { key, changedAt in
            lifecycleChangeByPanel[key] == changedAt
        }
        for candidate in candidates {
            let unchangedSince = backgroundWorkDrainRejections[candidate.key]
            let verdict = await Task.detached(priority: .utility) {
                ClaudeBackgroundWorkDrain.verdict(
                    agent: candidate.agent,
                    panelKey: candidate.key,
                    notBefore: candidate.notBefore,
                    processScopeShowsNoBackgroundShell: candidate.processScopeShowsNoBackgroundShell,
                    unchangedSince: unchangedSince,
                    now: checkedAt
                )
            }.value
            switch verdict {
            case .undecided:
                continue
            case .pending(let evidence):
                // The same transcript, scan window and process scope give the
                // same answer; don't read the transcript again until one changes.
                backgroundWorkDrainRejections[candidate.key] = evidence
                continue
            case .drained:
                backgroundWorkDrainRejections[candidate.key] = nil
            }
            // Nothing may have moved while the transcript was read.
            guard lifecycleChangeByPanel[candidate.key] == candidate.lifecycleChangedAt,
                  let workspace = appDelegate.workspaceContainingPanel(
                      panelId: candidate.key.panelId,
                      preferredWorkspaceId: candidate.key.workspaceId
                  )?.workspace,
                  workspace.agentLifecycleStatesByPanelId[candidate.key.panelId]?[ClaudeBackgroundWorkDrain.statusKey]
                    == .backgroundWorkPending else {
                continue
            }
            backgroundWorkDrainsJournaled[candidate.key] = .some(candidate.lifecycleChangedAt)
            AgentJournalLifecycleCenter.shared.observe(ClaudeBackgroundWorkDrain.drainedDraft(
                sessionId: candidate.agent.sessionId,
                workspaceId: candidate.key.workspaceId,
                panelId: candidate.key.panelId,
                observedAt: checkedAt
            ))
        }
    }

    struct BackgroundWorkDrainCandidate: Sendable {
        let key: AgentHibernationPanelKey
        let agent: SessionRestorableAgentSnapshot
        let notBefore: Date?
        let processScopeShowsNoBackgroundShell: Bool
        let lifecycleChangedAt: TimeInterval?
    }

    private func backgroundWorkDrainCandidates(
        appDelegate: AppDelegate,
        index: RestorableAgentSessionIndex,
        now: Date
    ) -> [BackgroundWorkDrainCandidate] {
        appDelegate.agentHibernationRecords(
            index: index,
            activityByPanel: activityByPanel,
            terminalInputByPanel: terminalInputByPanel,
            lifecycleChangeByPanel: lifecycleChangeByPanel
        ).compactMap { record in
            let claudeLifecycle = record.workspace
                .agentLifecycleStatesByPanelId[record.key.panelId]?[ClaudeBackgroundWorkDrain.statusKey]
            let lifecycleChangedAt = lifecycleChangeByPanel[record.key]
            guard ClaudeBackgroundWorkDrain.shouldCheck(
                agentKind: record.agent.kind,
                claudeLifecycle: claudeLifecycle,
                isHibernated: record.terminalPanel.isAgentHibernated,
                lifecycleChangedAt: lifecycleChangedAt,
                now: now.timeIntervalSince1970
            ) else { return nil }
            return BackgroundWorkDrainCandidate(
                key: record.key,
                agent: record.agent,
                // An unknown process start keeps every launch in scope.
                notBefore: record.processLiveness == .running ? record.backgroundWorkNotBefore : nil,
                processScopeShowsNoBackgroundShell: record.processLiveness == .running
                    && record.hasLiveProcess
                    && !record.containsUnrelatedProcess,
                lifecycleChangedAt: lifecycleChangedAt
            )
        }
    }
}

/// Decisions for the drain check, free of app state so tests can drive them.
enum ClaudeBackgroundWorkDrain {
    static let checkIntervalSeconds: Int = 60
    /// A pane that just entered the pending state is left alone this long: a
    /// finished task usually wakes Claude for another turn within seconds.
    static let quietSeconds: TimeInterval = 30
    static let nativeEvent = "cmux_background_work_drained"
    static let statusKey = "claude_code"

    static func shouldCheck(
        agentKind: RestorableAgentKind,
        claudeLifecycle: AgentHibernationLifecycleState?,
        isHibernated: Bool,
        lifecycleChangedAt: TimeInterval?,
        now: TimeInterval
    ) -> Bool {
        guard agentKind == .claude,
              claudeLifecycle == .backgroundWorkPending,
              !isHibernated else { return false }
        // No recorded change (an app relaunch restored the state) is old enough.
        guard let lifecycleChangedAt else { return true }
        return now - lifecycleChangedAt >= quietSeconds
    }

    /// The transcript and process evidence a rejected check read.
    struct Evidence: Equatable, Sendable {
        let transcriptPath: String
        let transcriptModifiedAt: Date
        let notBefore: Date?
        let processScopeShowsNoBackgroundShell: Bool
    }

    enum Verdict: Equatable, Sendable {
        case drained
        /// Nothing was read: a cron, a missing transcript or a recent write.
        case undecided
        /// Work may still run according to this evidence.
        case pending(Evidence)
    }

    /// Whether the agent's background work has ended. Bash and Monitor work
    /// that never wrote a notification counts as ended only when the process
    /// scope shows no background shell left under the agent. A session cron
    /// or scheduled wakeup leaves no such trace, so a session whose last Stop
    /// did not record its crons as absent is never settled here. A transcript
    /// written to within the quiet window means a turn may be running whose
    /// hook has not landed yet, so it is left for a later check.
    static func hasDrained(
        agent: SessionRestorableAgentSnapshot,
        panelKey: AgentHibernationPanelKey?,
        notBefore: Date?,
        processScopeShowsNoBackgroundShell: Bool,
        now: Date = Date(),
        homeDirectory: String = NSHomeDirectory(),
        hookStoreURL: URL = RestorableAgentKind.claude.hookStoreFileURL(),
        fileManager: FileManager = .default
    ) -> Bool {
        verdict(
            agent: agent,
            panelKey: panelKey,
            notBefore: notBefore,
            processScopeShowsNoBackgroundShell: processScopeShowsNoBackgroundShell,
            now: now,
            homeDirectory: homeDirectory,
            hookStoreURL: hookStoreURL,
            fileManager: fileManager
        ) == .drained
    }

    /// - Parameter unchangedSince: Evidence an earlier check rejected; when it
    ///   still holds, the transcript is not read again.
    static func verdict(
        agent: SessionRestorableAgentSnapshot,
        panelKey: AgentHibernationPanelKey?,
        notBefore: Date?,
        processScopeShowsNoBackgroundShell: Bool,
        unchangedSince: Evidence? = nil,
        now: Date = Date(),
        homeDirectory: String = NSHomeDirectory(),
        hookStoreURL: URL = RestorableAgentKind.claude.hookStoreFileURL(),
        fileManager: FileManager = .default
    ) -> Verdict {
        guard !sessionsWithoutCrons([agent.sessionId], hookStoreURL: hookStoreURL).isEmpty,
              let transcriptPath = AgentHibernationTranscriptGuard.resolveTranscriptPath(
                  agent: agent,
                  panelKey: panelKey,
                  homeDirectory: homeDirectory,
                  fileManager: fileManager
              ),
              let modifiedAt = (try? fileManager.attributesOfItem(atPath: transcriptPath))?[.modificationDate] as? Date,
              now.timeIntervalSince(modifiedAt) >= quietSeconds else { return .undecided }
        let evidence = Evidence(
            transcriptPath: transcriptPath,
            transcriptModifiedAt: modifiedAt,
            notBefore: notBefore,
            processScopeShowsNoBackgroundShell: processScopeShowsNoBackgroundShell
        )
        guard evidence != unchangedSince else { return .pending(evidence) }
        let drained = hasDrained(
            transcriptState: AgentHibernationTranscriptGuard.backgroundWorkTranscriptState(
                atPath: transcriptPath,
                notBefore: notBefore
            ),
            processScopeShowsNoBackgroundShell: processScopeShowsNoBackgroundShell
        )
        return drained ? .drained : .pending(evidence)
    }

    /// The sessions whose last Stop recorded no session crons. A record
    /// without the flag proves nothing, so it is left out.
    static func sessionsWithoutCrons(
        _ sessionIds: Set<String>,
        hookStoreURL: URL = RestorableAgentKind.claude.hookStoreFileURL()
    ) -> Set<String> {
        guard let data = try? Data(contentsOf: hookStoreURL),
              let state = try? JSONDecoder().decode(RestorableAgentHookSessionStoreFile.self, from: data) else {
            return []
        }
        return sessionIds.filter { sessionId in
            let record = state.sessions[sessionId]
                ?? state.sessions.values.first { $0.sessionId == sessionId }
            return record?.hadSessionCronsAtStop == false
        }
    }

    static func hasDrained(
        transcriptState: AgentHibernationTranscriptGuard.BackgroundWorkTranscriptState,
        processScopeShowsNoBackgroundShell: Bool
    ) -> Bool {
        switch transcriptState {
        case .allFinished:
            return true
        case .unfinishedProcessWorkOnly:
            return processScopeShowsNoBackgroundShell
        case .unfinishedInProcessWork, .noLaunchesSeen, .unreadable:
            return false
        }
    }

    /// The turn completion Claude would have sent had the finished work woken it.
    static func drainedDraft(
        sessionId: String,
        workspaceId: UUID,
        panelId: UUID,
        observedAt: Date
    ) -> AgentJournalEventDraft {
        AgentJournalEventDraft(
            kind: .turnCompleted,
            occurredAtMs: Int64(observedAt.timeIntervalSince1970 * 1_000),
            source: "claude",
            agentKey: statusKey,
            sessionId: sessionId,
            workspaceId: workspaceId.uuidString,
            surfaceId: panelId.uuidString,
            pendingWork: false,
            nativeEvent: nativeEvent,
            detail: "background work ended while the agent was idle"
        )
    }

    /// The Idle pill the Claude Stop hook writes, for a pane this check settled.
    static func idleStatusEntry(at date: Date = Date()) -> SidebarStatusEntry {
        SidebarStatusEntry(
            key: statusKey,
            value: String(localized: "agent.generic.notification.status.idle", defaultValue: "Idle"),
            icon: "pause.circle.fill",
            color: "#8E8E93",
            timestamp: date
        )
    }
}
