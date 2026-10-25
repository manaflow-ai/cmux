import CMUXAgentLaunch
import CmuxAgentJournal
import CmuxSettings
import CmuxSidebar
import Foundation

/// Moves a Claude pane to the next registered account when its account hits the usage limit,
/// while `automation.claudeAccountAutoSwitch` is on, and continues the conversation there.
///
/// The decisions are pure: ``ClaudeAccountAutoSwitchRequest`` picks what to do about a report,
/// ``ClaudeAccountAutoSwitchFollowUp`` what to do after the switch, and
/// ``ClaudeAccountAutoSwitchContinueGate`` when `continue` may be typed. This type runs them
/// against the live app. Like ``AgentAutoResumeCoordinator`` it sees live journal events only,
/// so replaying history never switches an account or types into a terminal.
@MainActor
final class ClaudeAccountAutoSwitchCoordinator {
    static let shared = ClaudeAccountAutoSwitchCoordinator()

    /// Sidebar status key of the "Claude account: <from> → <to> (auto)" row.
    static let statusKey = "claude_account_switch"

    private let homeDirectory: String
    private let exhaustionStore: ClaudeAccountExhaustionStore
    /// Panes whose report is being handled. A report arriving meanwhile is dropped: the pane is
    /// already moving, and its new account reports its own limit later.
    private var inFlightPanelIds = Set<UUID>()
    /// The last report handled per pane, so one report switches at most once.
    private var handledEventIds: [UUID: String] = [:]
    /// Panes waiting for Claude's empty prompt to be typed `continue` into.
    private var continueGates: [UUID: ClaudeAccountAutoSwitchContinueGate] = [:]
    private var continueTasks: [UUID: Task<Void, Never>] = [:]
    /// When each pane got its auto-switch status row; its Claude session ending after that
    /// clears the row, while the replaced Claude's own end, which comes earlier, does not.
    private var announcedAtMs: [UUID: Int64] = [:]

    /// - Parameters:
    ///   - homeDirectory: Resolves the default account and the exhaustion file.
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
        if !continueGates.isEmpty || !announcedAtMs.isEmpty {
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
        // A new limit supersedes a continue still waiting from an earlier switch.
        cancelContinue(panelId: panelId)
        Task { [weak self] in
            await self?.handle(request, workspace: workspace)
            self?.inFlightPanelIds.remove(panelId)
        }
    }

    /// Feeds the pane's own Claude events to its waiting continue, and clears its status row
    /// once its session ends.
    private func followSession(_ draft: AgentJournalEventDraft) {
        guard draft.source == "claude", !draft.isSubagent, draft.unattributedReason == nil,
              let panelId = draft.surfaceId.flatMap(UUID.init(uuidString:)) else { return }
        continueGates[panelId]?.observe(kind: draft.kind)
        if draft.kind == .sessionEnded, let announcedAt = announcedAtMs[panelId], draft.occurredAtMs >= announcedAt {
            announcedAtMs[panelId] = nil
            AppDelegate.shared?.workspaceContainingPanel(panelId: panelId)?.workspace
                .clearStatusEntry(key: Self.statusKey, panelId: panelId)
        }
    }

    private func handle(_ request: ClaudeAccountAutoSwitchRequest, workspace: Workspace) async {
        let panelId = request.panelId
        let home = homeDirectory
        // Remote panes are settled here, before anything is read or marked.
        let pane = workspace.claudeAccountAutoSwitchPane(panelId: panelId)
        let trustedKeys = await Self.trustedAccountKeys(pane: pane, homeDirectory: home)
        let now = Date()
        let action = request.action(
            pane: pane,
            exhaustedKeys: Set(exhaustionStore.exhaustedUntil(now: now).keys),
            isTrusted: { trustedKeys.contains($0.exhaustionKey(homeDirectory: home)) },
            now: now,
            timeZone: .current,
            homeDirectory: home
        )
        // The limit is a fact whether or not a switch follows.
        if let exhaustion = action.exhaustion {
            markExhausted(exhaustion)
        }
        guard case .switchAccount(let target, let sendContinue, let exhaustion) = action else {
            log("claudeAccount.autoSwitch panel=\(panelId.uuidString.prefix(5)) action=\(action)")
            return
        }
        // Armed before the switch, so the resumed Claude's SessionStart counts even when it
        // lands before the switch returns.
        if sendContinue {
            continueGates[panelId] = ClaudeAccountAutoSwitchContinueGate()
        }
        let result = await workspace.switchClaudeAccount(
            panelId: panelId,
            toAccountNamed: target.name,
            trigger: .automatic
        )
        switch ClaudeAccountAutoSwitchFollowUp(result: result, sendContinue: sendContinue) {
        case .announce(let from, let to, let typeContinue):
            let announcement = ClaudeAccountAutoSwitchAnnouncement(
                from: from,
                to: to,
                reset: exhaustion.quotedReset,
                continues: typeContinue
            )
            announce(
                announcement,
                notification: announcement.notification(now: Date(), calendar: .current),
                workspace: workspace,
                panelId: panelId
            )
            if typeContinue {
                waitThenTypeContinue(panelId: panelId, workspaceId: workspace.id)
            } else {
                continueGates[panelId] = nil
            }
        case .announceWithoutResume(let from, let to):
            continueGates[panelId] = nil
            announce(
                ClaudeAccountAutoSwitchAnnouncement(from: from, to: to, reset: exhaustion.quotedReset, continues: false),
                notification: ClaudeAccountSwitchSocketOutcome.finished(result).resumeNotification,
                workspace: workspace,
                panelId: panelId
            )
        case .keepUsageLimitStatus:
            continueGates[panelId] = nil
        }
        log("claudeAccount.autoSwitch panel=\(panelId.uuidString.prefix(5)) to=\(target.name) result=\(result)")
    }

    /// The accounts other than the current one that already trust the session's folder. Read
    /// off the main actor: `.claude.json` holds every project's history and can be large.
    private nonisolated static func trustedAccountKeys(
        pane: ClaudeAccountAutoSwitchRequest.Pane,
        homeDirectory: String
    ) async -> Set<String> {
        guard case .local(let current, let registry, let workingDirectory?) = pane else { return [] }
        let currentKey = current.exhaustionKey(homeDirectory: homeDirectory)
        let candidates = registry.accounts.filter { $0.exhaustionKey(homeDirectory: homeDirectory) != currentKey }
        return await Task.detached(priority: .utility) {
            Set(candidates.filter {
                ClaudeConfigTrustReader.isTrusted(workingDirectory: workingDirectory, account: $0, homeDirectory: homeDirectory)
            }.map { $0.exhaustionKey(homeDirectory: homeDirectory) })
        }.value
    }

    private func markExhausted(_ exhaustion: ClaudeAccountAutoSwitchAction.Exhaustion) {
        do {
            try exhaustionStore.markExhausted(accountKey: exhaustion.accountKey, until: exhaustion.until)
        } catch {
            log("claudeAccount.autoSwitch markExhausted.failed account=\(exhaustion.account.name) error=\(error)")
        }
    }

    /// Shows the status row and posts `notification` on the pane, or on its workspace once the
    /// pane is gone, without moving focus.
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
        announcedAtMs[panelId] = Int64(Date().timeIntervalSince1970 * 1000)
        let paneIsLive = AppDelegate.shared?.agentNotificationDeliveryTarget(
            claimedTabId: workspace.id,
            surfaceId: panelId
        ) != nil
        notification?.post(workspaceId: workspace.id, panelId: panelId, paneIsLive: paneIsLive) {
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

    private func waitThenTypeContinue(panelId: UUID, workspaceId: UUID) {
        continueTasks.removeValue(forKey: panelId)?.cancel()
        continueTasks[panelId] = Task { [weak self] in
            let clock = ContinuousClock()
            let start = clock.now
            // The terminal grid publishes no change events, so Claude's prompt is polled: a
            // bounded wait (the gate gives up after its timeout), cancelled by a newer report.
            while !Task.isCancelled {
                try? await clock.sleep(for: ClaudeAccountAutoSwitchContinueGate.pollInterval)
                guard !Task.isCancelled, let self,
                      !self.pollContinue(panelId: panelId, workspaceId: workspaceId, elapsed: start.duration(to: clock.now))
                else { return }
            }
        }
    }

    /// One poll of a waiting continue. Returns whether the wait is over.
    private func pollContinue(panelId: UUID, workspaceId: UUID, elapsed: Duration) -> Bool {
        guard let gate = continueGates[panelId] else { return true }
        guard let workspace = AppDelegate.shared?.workspaceContainingPanel(
            panelId: panelId,
            preferredWorkspaceId: workspaceId
        )?.workspace,
            let terminal = workspace.terminalPanel(for: panelId) else {
            finishContinue(panelId: panelId, outcome: ClaudeAccountAutoSwitchContinueGate.GiveUpReason.paneGone.rawValue)
            return true
        }
        let step = gate.step(
            elapsed: elapsed,
            isEnabled: isEnabled,
            responseRunning: workspace.isClaudeResponseRunning(panelId: panelId)
        ) {
            AgentAutoResumeCoordinator.shared.screenState(for: terminal.surface)
        }
        switch step {
        case .wait:
            return false
        case .giveUp(let reason):
            finishContinue(panelId: panelId, outcome: reason.rawValue)
            return true
        case .send:
            // Ended first, so `continue` is typed at most once.
            finishContinue(panelId: panelId, outcome: "send")
            guard terminal.sendTextResult(AgentAutoResumeCoordinator.resumePrompt).accepted,
                  terminal.sendNamedKeyResult("return").accepted else {
                log("claudeAccount.autoSwitch panel=\(panelId.uuidString.prefix(5)) continue=rejected")
                return true
            }
            log("claudeAccount.autoSwitch panel=\(panelId.uuidString.prefix(5)) continue=sent")
            return true
        }
    }

    private func finishContinue(panelId: UUID, outcome: String) {
        continueGates[panelId] = nil
        continueTasks[panelId] = nil
        log("claudeAccount.autoSwitch panel=\(panelId.uuidString.prefix(5)) continueWait=\(outcome)")
    }

    private func cancelContinue(panelId: UUID) {
        continueGates[panelId] = nil
        continueTasks.removeValue(forKey: panelId)?.cancel()
    }

    private func log(_ message: @autoclosure () -> String) {
#if DEBUG
        cmuxDebugLog(message())
#endif
    }
}
