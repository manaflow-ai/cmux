import CMUXAgentLaunch
import CmuxAgentJournal
import CmuxFoundation
import CmuxSettings
import CmuxSidebar
import Foundation

/// Moves a Claude pane to the next registered account when its account hits the usage limit,
/// while `automation.claudeAccountAutoSwitch` is on, and continues the conversation there.
///
/// The decisions are pure: ``ClaudeAccountAutoSwitchRequest`` picks what to do about a report,
/// ``ClaudeAccountAutoSwitchFollowUp`` what to do after the switch, and
/// ``ClaudeAccountAutoSwitchContinueGate`` with ``ClaudeAccountAutoSwitchForegroundCheck`` when
/// `continue` may be typed. ``ClaudeAccountAutoSwitchLedger`` is what it remembers. This type
/// runs them against the live app. Like ``AgentAutoResumeCoordinator`` it sees live journal
/// events only, so replaying history never switches an account or types into a terminal.
@MainActor
final class ClaudeAccountAutoSwitchCoordinator {
    static let shared = ClaudeAccountAutoSwitchCoordinator()

    /// Sidebar status key of the "Claude account: <from> → <to> (auto)" row.
    static let statusKey = "claude_account_switch"

    private let homeDirectory: String
    private let exhaustionStore: ClaudeAccountExhaustionStore
    private var ledger = ClaudeAccountAutoSwitchLedger()
    /// Panes whose report is being handled. A report arriving meanwhile is dropped: the pane is
    /// already moving, and its new account reports its own limit later.
    private var inFlightPanelIds = Set<UUID>()
    /// The last report handled per pane, so one report switches at most once.
    private var handledEventIds: [UUID: String] = [:]
    /// The pane's Claude events seen while its switch runs, replayed into its gate, so a
    /// `SessionStart` that lands before the switch returns still counts.
    private var eventsDuringSwitch: [UUID: [(kind: AgentJournalEventKind, sessionId: String?, occurredAtMs: Int64)]] = [:]
    /// Panes waiting for the resumed Claude's idle prompt to be typed `continue` into.
    private var pendingContinues: [UUID: PendingContinue] = [:]
    /// When each pane got its auto-switch status row; its Claude session ending after that
    /// clears the row, while the replaced Claude's own end, which comes earlier, does not.
    private var announcedAtMs: [UUID: Int64] = [:]

    private struct PendingContinue {
        var gate: ClaudeAccountAutoSwitchContinueGate
        let announcement: ClaudeAccountAutoSwitchAnnouncement
        let workspaceId: UUID
        /// When the switch started; only a Claude started later is the resumed one.
        let switchStartedAt: Date
        var task: Task<Void, Never>?
    }

    /// - Parameters:
    ///   - homeDirectory: Resolves the default account, the user-level config and the
    ///     exhaustion file.
    ///   - exhaustionStore: Where exhausted accounts are recorded; defaults to the file the CLI
    ///     reads (`~/.cmuxterm/claude-account-exhaustion.json`).
    init(homeDirectory: String = NSHomeDirectory(), exhaustionStore: ClaudeAccountExhaustionStore? = nil) {
        self.homeDirectory = homeDirectory
        self.exhaustionStore = exhaustionStore ?? ClaudeAccountExhaustionStore(
            fileURL: ClaudeAccountExhaustionStore.defaultFileURL(homeDirectory: homeDirectory)
        )
    }

    private var isEnabled: Bool {
        AutomationCatalogSection().claudeAccountAutoSwitch.value(in: .standard)
    }

    /// Observes one live journal event. Cheap for everything but a usage-limit report.
    func observe(_ draft: AgentJournalEventDraft) {
        if !pendingContinues.isEmpty || !announcedAtMs.isEmpty || !inFlightPanelIds.isEmpty || ledger.tracksSwitches {
            followSession(draft)
        }
        guard let request = ClaudeAccountAutoSwitchRequest(draft: draft, isEnabled: isEnabled) else { return }
        let panelId = request.panelId
        guard handledEventIds[panelId] != request.eventId else { return }
        guard let workspace = AppDelegate.shared?.workspaceContainingPanel(
            panelId: panelId,
            preferredWorkspaceId: request.workspaceId
        )?.workspace else {
            log("claudeAccount.autoSwitch panel=\(panelId.uuidString.prefix(5)) skip=paneNotFound")
            return
        }
        guard inFlightPanelIds.insert(panelId).inserted else {
            log("claudeAccount.autoSwitch panel=\(panelId.uuidString.prefix(5)) skip=inFlight")
            return
        }
        handledEventIds[panelId] = request.eventId
        Task { [weak self] in
            await self?.handle(request, workspace: workspace)
            self?.inFlightPanelIds.remove(panelId)
            self?.eventsDuringSwitch[panelId] = nil
        }
    }

    /// Input reached the pane, from the user or a client. Called synchronously from the pane's
    /// explicit-input path: a waiting continue ends before anything else can type, and a later
    /// report knows the pane was in use.
    func userDidInput(panelId: UUID) {
        ledger.noteInput(panelId: panelId, atMs: Self.nowMs())
        pendingContinues[panelId]?.gate.userDidInput()
    }

    /// Whether input reached the pane after `afterMs`, for other unattended restarts' gates.
    func receivedInput(panelId: UUID, afterMs: Int64) -> Bool { ledger.receivedInput(panelId: panelId, after: afterMs) }

    /// Feeds the pane's own Claude events to its switch and waiting continue, resets its attempt
    /// count when it finishes a turn, and clears its status row once its session ends.
    private func followSession(_ draft: AgentJournalEventDraft) {
        guard draft.source == "claude", !draft.isSubagent, draft.unattributedReason == nil,
              let panelId = draft.surfaceId.flatMap(UUID.init(uuidString:)) else { return }
        if inFlightPanelIds.contains(panelId) {
            eventsDuringSwitch[panelId, default: []].append((draft.kind, draft.sessionId, draft.occurredAtMs))
        }
        pendingContinues[panelId]?.gate.observe(kind: draft.kind, sessionId: draft.sessionId, occurredAtMs: draft.occurredAtMs)
        if draft.kind == .turnCompleted {
            ledger.noteTurnCompleted(panelId: panelId)
        }
        if draft.kind == .sessionEnded, let announcedAt = announcedAtMs[panelId], draft.occurredAtMs >= announcedAt {
            announcedAtMs[panelId] = nil
            AppDelegate.shared?.workspaceContainingPanel(panelId: panelId)?.workspace
                .clearStatusEntry(key: Self.statusKey, panelId: panelId)
        }
    }

    private func handle(_ request: ClaudeAccountAutoSwitchRequest, workspace: Workspace) async {
        let panelId = request.panelId
        let home = homeDirectory
        // Remote and already-switching panes are settled here, before anything is read or marked.
        let pane = workspace.claudeAccountAutoSwitchPane(panelId: panelId)
        let candidates = await Self.candidateFacts(pane: pane, homeDirectory: home)
        let now = Date()
        var action = request.action(
            pane: pane,
            isEnabled: isEnabled,
            storedExhaustion: exhaustionStore.exhaustedUntil(now: now),
            ledger: ledger,
            sourceScreen: Self.screenState(of: workspace, panelId: panelId),
            isUsable: { candidates.usable.contains($0.exhaustionKey(homeDirectory: home)) },
            isTrusted: { candidates.trusted.contains($0.exhaustionKey(homeDirectory: home)) },
            now: now,
            timeZone: .current,
            homeDirectory: home
        )
        // A report that counts supersedes a continue still waiting from an earlier switch; a late
        // one from the replaced Claude leaves it alone.
        if action.supersedesPendingContinue { cancelContinue(panelId: panelId) }
        // The limit is a fact whether or not a switch follows. It is remembered even when the
        // file write fails; a switch whose source could not be written is held back.
        if let exhaustion = action.exhaustion {
            ledger.recordExhaustion(accountKey: exhaustion.accountKey, until: exhaustion.until)
            action = action.recording(succeeded: writeExhaustion(exhaustion))
        }
        log("claudeAccount.autoSwitch panel=\(panelId.uuidString.prefix(5)) action=\(action)")
        switch action {
        case .ignore, .markExhaustedOnly:
            return
        case .holdBack(let exhaustion, let reason):
            post(
                ClaudeAccountAutoSwitchAnnouncement.holdBackNotification(from: exhaustion.account.name, reason: reason),
                workspaceId: workspace.id,
                panelId: panelId
            )
        case .switchAccount(let target, let sendContinue, let exhaustion):
            await switchAccount(
                request: request,
                workspace: workspace,
                to: target,
                sendContinue: sendContinue,
                exhaustion: exhaustion
            )
        }
    }

    private func switchAccount(
        request: ClaudeAccountAutoSwitchRequest,
        workspace: Workspace,
        to target: ClaudeAccount,
        sendContinue: Bool,
        exhaustion: ClaudeAccountAutoSwitchAction.Exhaustion
    ) async {
        let panelId = request.panelId
        let switchStartedAt = Date()
        let result = await workspace.switchClaudeAccount(
            panelId: panelId,
            toAccountNamed: target.name,
            trigger: .automatic,
            paneIsFree: { [weak self, weak workspace] in
                guard let self, let workspace else { return false }
                return self.paneInUse(request, workspace: workspace) == nil
            }
        )
        log("claudeAccount.autoSwitch panel=\(panelId.uuidString.prefix(5)) to=\(target.name) result=\(result)")
        switch ClaudeAccountAutoSwitchFollowUp(result: result, sendContinue: sendContinue) {
        case .announce(let from, let to, let sessionId, let typeContinue):
            ledger.noteAutomaticSwitch(panelId: panelId, atMs: Self.nowMs())
            let announcement = ClaudeAccountAutoSwitchAnnouncement(
                from: from,
                to: to,
                reset: exhaustion.quotedReset,
                continues: typeContinue
            )
            // A trusted switch is announced by its continue wait, once the resumed Claude settled:
            // that Claude's SessionStart hook clears the pane's notifications, so one posted now
            // would vanish within a second. An untrusted target's Claude stops at the trust
            // prompt before any SessionStart, so its notice goes out now.
            announce(
                announcement,
                notification: typeContinue ? nil : announcement.notification(now: Date(), calendar: .current),
                workspace: workspace,
                panelId: panelId
            )
            if typeContinue {
                waitThenTypeContinue(
                    panelId: panelId,
                    gate: ClaudeAccountAutoSwitchContinueGate(sessionId: sessionId),
                    announcement: announcement,
                    workspaceId: workspace.id,
                    switchStartedAt: switchStartedAt
                )
            }
        case .announceWithoutResume(let from, let to):
            ledger.noteAutomaticSwitch(panelId: panelId, atMs: Self.nowMs())
            announce(
                ClaudeAccountAutoSwitchAnnouncement(from: from, to: to, reset: exhaustion.quotedReset, continues: false),
                notification: ClaudeAccountSwitchSocketOutcome.finished(result).resumeNotification,
                workspace: workspace,
                panelId: panelId
            )
        case .keepUsageLimitStatus:
            break
        case .paneInUse:
            post(
                ClaudeAccountAutoSwitchAnnouncement.holdBackNotification(
                    from: exhaustion.account.name,
                    reason: paneInUse(request, workspace: workspace) ?? .userInput
                ),
                workspaceId: workspace.id,
                panelId: panelId
            )
        }
    }

    /// Why the report's pane must not restart now, read synchronously; `nil` when it may.
    private func paneInUse(
        _ request: ClaudeAccountAutoSwitchRequest,
        workspace: Workspace
    ) -> ClaudeAccountAutoSwitchAction.HoldBack? {
        ClaudeAccountAutoSwitchAction.HoldBack.paneInUse(
            receivedInputSinceReport: ledger.receivedInput(panelId: request.panelId, after: request.occurredAtMs),
            screen: Self.screenState(of: workspace, panelId: request.panelId)
        )
    }

    /// The pane's screen as the shared prompt classifier reads it; `.unknown` when it is gone.
    private static func screenState(of workspace: Workspace, panelId: UUID) -> AgentAutoResumeCoordinator.ScreenState {
        guard let terminal = workspace.terminalPanel(for: panelId) else { return .unknown }
        return AgentAutoResumeCoordinator.shared.screenState(for: terminal.surface)
    }

    /// The accounts other than the current one that have a Claude config, and those of them that
    /// already trust the session's folder. Read off the main actor: `.claude.json` holds every
    /// project's history and can be large.
    private nonisolated static func candidateFacts(
        pane: ClaudeAccountAutoSwitchRequest.Pane,
        homeDirectory: String
    ) async -> (usable: Set<String>, trusted: Set<String>) {
        guard case .local(let current, let registry, let workingDirectory) = pane else { return ([], []) }
        let currentKey = current.exhaustionKey(homeDirectory: homeDirectory)
        let candidates = registry.accounts.filter { $0.exhaustionKey(homeDirectory: homeDirectory) != currentKey }
        return await Task.detached(priority: .utility) {
            var usable = Set<String>()
            var trusted = Set<String>()
            for account in candidates where ClaudeConfigTrustReader.hasConfig(account: account, homeDirectory: homeDirectory) {
                let key = account.exhaustionKey(homeDirectory: homeDirectory)
                usable.insert(key)
                if let workingDirectory,
                   ClaudeConfigTrustReader.isTrusted(workingDirectory: workingDirectory, account: account, homeDirectory: homeDirectory) {
                    trusted.insert(key)
                }
            }
            return (usable, trusted)
        }.value
    }

    /// Writes the exhaustion to the file the CLI reads. Returns whether it was written.
    private func writeExhaustion(_ exhaustion: ClaudeAccountAutoSwitchAction.Exhaustion) -> Bool {
        do {
            try exhaustionStore.markExhausted(accountKey: exhaustion.accountKey, until: exhaustion.until)
            return true
        } catch {
            log("claudeAccount.autoSwitch markExhausted.failed account=\(exhaustion.account.name) error=\(error)")
            return false
        }
    }

    /// Shows the status row and posts `notification`.
    private func announce(
        _ announcement: ClaudeAccountAutoSwitchAnnouncement,
        notification: ClaudeAccountSwitchSocketOutcome.ResumeNotification?,
        workspace: Workspace,
        panelId: UUID
    ) {
        workspace.setStatusEntry(
            SidebarStatusEntry(
                key: Self.statusKey,
                value: announcement.statusText,
                icon: "arrow.left.arrow.right",
                color: "#4C8DFF"
            ),
            key: Self.statusKey,
            panelId: panelId
        )
        announcedAtMs[panelId] = Self.nowMs()
        if let notification {
            post(notification, workspaceId: workspace.id, panelId: panelId)
        }
    }

    /// Posts `notification` on the pane, or on its workspace once the pane is gone, without
    /// moving focus.
    private func post(_ notification: ClaudeAccountSwitchSocketOutcome.ResumeNotification, workspaceId: UUID, panelId: UUID) {
        let paneIsLive = AppDelegate.shared?.agentNotificationDeliveryTarget(
            claimedTabId: workspaceId,
            surfaceId: panelId
        ) != nil
        notification.post(workspaceId: workspaceId, panelId: panelId, paneIsLive: paneIsLive) {
            tabId, surfaceId, title, subtitle, body in
            TerminalController.shared.deliverNotificationSynchronously(
                tabId: tabId,
                surfaceId: surfaceId,
                title: title,
                subtitle: subtitle,
                body: body
            )
        }
    }

    // MARK: Continue

    private func waitThenTypeContinue(
        panelId: UUID,
        gate: ClaudeAccountAutoSwitchContinueGate,
        announcement: ClaudeAccountAutoSwitchAnnouncement,
        workspaceId: UUID,
        switchStartedAt: Date
    ) {
        var gate = gate
        for event in eventsDuringSwitch[panelId] ?? [] {
            gate.observe(kind: event.kind, sessionId: event.sessionId, occurredAtMs: event.occurredAtMs)
        }
        pendingContinues[panelId] = PendingContinue(
            gate: gate,
            announcement: announcement,
            workspaceId: workspaceId,
            switchStartedAt: switchStartedAt
        )
        pendingContinues[panelId]?.task = Task { [weak self] in
            let clock = ContinuousClock()
            let start = clock.now
            // Polled because nothing signals a change of the terminal grid: the screen is read
            // with the pull-only mobileRenderGridFrame. Bounded (the gate gives up after 60 s),
            // cancelled by a newer report or the pane's input; the session start, the hook's
            // status and user input that gate it are events, not timing.
            while !Task.isCancelled {
                try? await clock.sleep(for: ClaudeAccountAutoSwitchContinueGate.pollInterval)
                guard !Task.isCancelled, let self,
                      !self.pollContinue(panelId: panelId, elapsed: start.duration(to: clock.now))
                else { return }
            }
        }
    }

    /// One poll of a waiting continue. Returns whether the wait is over.
    private func pollContinue(panelId: UUID, elapsed: Duration) -> Bool {
        guard var pending = pendingContinues[panelId] else { return true }
        guard let workspace = AppDelegate.shared?.workspaceContainingPanel(
            panelId: panelId,
            preferredWorkspaceId: pending.workspaceId
        )?.workspace,
            let terminal = workspace.terminalPanel(for: panelId) else {
            finishContinue(panelId: panelId, reason: .paneGone)
            return true
        }
        let switchStartedAt = pending.switchStartedAt
        let poll = pending.gate.poll(
            elapsed: elapsed,
            isEnabled: isEnabled,
            responseRunning: workspace.isClaudeResponseRunning(panelId: panelId),
            paneStatusUpdatedAtMs: {
                workspace.agentStatusEntry(key: Workspace.claudeAgentLifecycleKey, panelId: panelId)
                    .map { Int64($0.timestamp.timeIntervalSince1970 * 1000) }
            },
            screen: {
                guard let frame = terminal.surface.mobileRenderGridFrame(
                    stateSeq: 0,
                    includeTheme: false,
                    anchor: .screen
                )?.frame else {
                    return ClaudeAccountAutoSwitchContinueGate.Screen(state: .unknown, showsInterruptHint: false)
                }
                return ClaudeAccountAutoSwitchContinueGate.Screen(frame: frame)
            },
            claudeInForeground: {
                ClaudeAccountAutoSwitchForegroundCheck.claudeOwnsTerminal(
                    registered: workspace.claudeAgentProcesses(panelId: panelId),
                    startedAfter: switchStartedAt,
                    paneTTYDevice: terminal.surface.controllingTTYDeviceIdentifier,
                    facts: ClaudeAccountAutoSwitchForegroundCheck.liveFacts(pid:)
                )
            }
        )
        pendingContinues[panelId]?.gate = pending.gate
        switch poll.step {
        case .wait:
            if poll.announce { postSwitchAnnouncement(pending, panelId: panelId) }
            return false
        case .giveUp(let reason):
            finishContinue(panelId: panelId, reason: reason, includingSwitch: poll.announce)
            return true
        case .send:
            // Ended first, so `continue` is typed at most once and its own input path finds no gate.
            pendingContinues[panelId] = nil
            if poll.announce { postSwitchAnnouncement(pending, panelId: panelId) }
            guard terminal.sendTextResult(AgentAutoResumeCoordinator.resumePrompt).accepted,
                  terminal.sendNamedKeyResult("return").accepted else {
                log("claudeAccount.autoSwitch panel=\(panelId.uuidString.prefix(5)) continue=rejected")
                return true
            }
            log("claudeAccount.autoSwitch panel=\(panelId.uuidString.prefix(5)) continue=sent")
            return true
        }
    }

    /// Posts the "Claude account switched" notification a trusted switch owes.
    private func postSwitchAnnouncement(_ pending: PendingContinue, panelId: UUID) {
        log("claudeAccount.autoSwitch panel=\(panelId.uuidString.prefix(5)) announced")
        post(pending.announcement.notification(now: Date(), calendar: .current), workspaceId: pending.workspaceId, panelId: panelId)
    }

    /// Ends a waiting continue without typing and says why, together with the switch itself
    /// when that was not announced yet.
    ///
    /// - Parameter includingSwitch: What the gate's last poll decided; `nil` asks the gate,
    ///   for a wait the coordinator ends itself.
    private func finishContinue(
        panelId: UUID,
        reason: ClaudeAccountAutoSwitchContinueGate.GiveUpReason,
        includingSwitch: Bool? = nil
    ) {
        guard var pending = pendingContinues.removeValue(forKey: panelId) else { return }
        let includeSwitch = includingSwitch ?? pending.gate.announceIfOwed()
        log("claudeAccount.autoSwitch panel=\(panelId.uuidString.prefix(5)) continueWait=\(reason.rawValue) announced=\(includeSwitch)")
        post(
            pending.announcement.notContinuedNotification(
                reason: reason,
                includingSwitch: includeSwitch,
                now: Date(),
                calendar: .current
            ),
            workspaceId: pending.workspaceId,
            panelId: panelId
        )
    }

    /// Drops a waiting continue: a newer report for the pane brings its own notice. A switch not
    /// announced yet still is, so the user learns the pane moved.
    private func cancelContinue(panelId: UUID) {
        guard var pending = pendingContinues.removeValue(forKey: panelId) else { return }
        pending.task?.cancel()
        if pending.gate.announceIfOwed() {
            postSwitchAnnouncement(pending, panelId: panelId)
        }
    }

    private static func nowMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }

    private func log(_ message: @autoclosure () -> String) {
#if DEBUG
        cmuxDebugLog(message())
#endif
    }
}
