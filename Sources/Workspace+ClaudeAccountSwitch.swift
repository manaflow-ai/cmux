import CMUXAgentLaunch
import CmuxFoundation
import CmuxTerminal
import Darwin
import Foundation

extension Workspace {
    /// Panes with a switch in flight. Keyed by panel id across workspaces because a pane keeps
    /// its id when it moves, and a second switch must still see the first one.
    @MainActor private static var claudeAccountSwitchInFlightPanelIds: Set<UUID> = []

    /// Upper bound on waiting for the replaced Claude process to exit before the re-sync. A
    /// Claude still running after it gets no resume typed.
    private static let claudeAccountSwitchProcessExitTimeout: Duration = .seconds(3)

    /// The Claude accounts registered for this pane: the user `cmux.json` plus the nearest
    /// project `.cmux/cmux.json` above the pane's working directory.
    func claudeAccountRegistry(forPanelId panelId: UUID) -> ClaudeAccountRegistry {
        ClaudeAccountRegistry.load(
            homeDirectory: NSHomeDirectory(),
            workingDirectory: resolvedTerminalStartupWorkingDirectory(
                requestedWorkingDirectory: nil,
                sourcePanelId: panelId
            ),
            sanitize: { try JSONCParser.preprocess(data: $0) }
        )
    }

    /// The account the pane's Claude session runs under, or `nil` when the pane has no Claude
    /// agent. Reads cached agent state only, so it may lag a just-started session.
    @MainActor
    func currentClaudeAccount(panelId: UUID) -> ClaudeAccount? {
        guard let snapshot = cachedClaudeAgentSnapshot(panelId: panelId) else { return nil }
        return claudeAccountRegistry(forPanelId: panelId)
            .account(forEnvironment: snapshot.launchCommand?.environment)
    }

    /// The agent lifecycle key Claude Code reports its running state under.
    static let claudeAgentLifecycleKey = "claude_code"

    /// Whether the pane's Claude is mid-response. A switch replaces the pane's process and stops
    /// that response, so callers confirm before switching such a pane.
    @MainActor
    func isClaudeResponseRunning(panelId: UUID) -> Bool {
        hasRunningAgentLifecycle(key: Self.claudeAgentLifecycleKey, panelId: panelId)
    }

    /// Whether the pane has a Claude agent. Reads cached agent state only and never loads the
    /// account registry, so it is cheap enough for every command palette refresh.
    @MainActor
    func hasClaudeAgent(panelId: UUID) -> Bool {
        cachedClaudeAgentSnapshot(panelId: panelId) != nil
    }

    /// The Switch Claude Account rows for the pane, shared by the terminal context menu and the
    /// command palette. `nil` hides both: the pane has no Claude agent, runs on another machine,
    /// or has fewer than two registered accounts.
    @MainActor
    func claudeAccountSwitchMenuModel(panelId: UUID) -> ClaudeAccountSwitchMenuModel? {
        // Checked before the registry load, so panes without Claude never touch the disk.
        guard let snapshot = cachedClaudeAgentSnapshot(panelId: panelId),
              !terminalRunsOnAnotherMachine(panelId) else {
            return nil
        }
        let registry = claudeAccountRegistry(forPanelId: panelId)
        return ClaudeAccountSwitchMenuModel(
            registry: registry,
            current: registry.account(forEnvironment: snapshot.launchCommand?.environment)
        )
    }

    /// Moves the pane's Claude session to another registered account and resumes it there.
    ///
    /// The transcript is copied into the target account first; if that fails the pane is left
    /// alone, so a switch never starts a fresh conversation. A session with no conversation yet
    /// is refused there with ``ClaudeAccountSwitchRefusal/noConversationYet``, and copies that went
    /// on under both accounts with ``ClaudeAccountSwitchRefusal/transcriptDiverged(newerAccount:)``.
    /// A Claude the pane's restart would not stop (inside tmux or screen, or detached) is refused
    /// with ``ClaudeAccountSwitchResult/agentNotOwnedByPane``. The surface then respawns with the
    /// target's account keys (see ``ClaudeAccountSwitchSurfaceEnvironment``), the transcript is
    /// synced again once the old Claude has exited, and `claude --resume` is typed into the new
    /// shell once it reports a prompt. A resume that cannot be typed, or must not be because the
    /// old Claude is still running, returns
    /// ``ClaudeAccountSwitchResult/switchedWithoutResume(_:_:_:)`` with the built command. The
    /// pane stays marked as switching until then. Remote panes are refused. Confirming a running
    /// turn is the caller's job; this never asks.
    @MainActor
    func switchClaudeAccount(
        panelId: UUID,
        toAccountNamed name: String,
        trigger: ClaudeAccountSwitchTrigger
    ) async -> ClaudeAccountSwitchResult {
        guard Self.claudeAccountSwitchInFlightPanelIds.insert(panelId).inserted else {
            return .alreadySwitching
        }
        defer { Self.claudeAccountSwitchInFlightPanelIds.remove(panelId) }

        guard let candidate = await claudeAccountSwitchCandidateSnapshot(panelId: panelId) else {
            return .notClaude
        }
        guard !terminalRunsOnAnotherMachine(panelId) else { return .remoteUnsupported }
        // A session cmux cannot confirm as the pane's live one would resume the wrong conversation.
        guard let snapshot = await authoritativeForkSnapshot(
            selected: candidate,
            panelId: panelId,
            isRemoteContext: false
        ) else {
            return .refused(.noClaudeSession)
        }

        let plan: ClaudeAccountSwitchPlan
        switch ClaudeAccountSwitchPlanner.plan(
            sessionID: snapshot.sessionId,
            workingDirectory: snapshot.workingDirectory ?? snapshot.launchCommand?.workingDirectory,
            launchEnvironment: snapshot.launchCommand?.environment,
            targetName: name,
            registry: claudeAccountRegistry(forPanelId: panelId),
            homeDirectory: NSHomeDirectory()
        ) {
        case .success(let planned):
            plan = planned
        case .failure(let refusal):
            return .refused(refusal)
        }
        // Built before anything changes, so an unresumable session never costs the pane its agent.
        let resume = ClaudeAccountSwitchResumeInput(snapshot: snapshot, plan: plan)
        guard let resumeCommand = resume.posixCommand(), let resumeInput = resume.typedInput() else {
            return .refused(.noClaudeSession)
        }
        // Restarting the pane stops only a Claude on the pane's own terminal; one in tmux or
        // detached would keep writing this session while the resumed Claude continues it.
        // Checked before the transcript is copied, so a refused switch changes nothing.
        guard claudeAccountSwitchAgentsOwnedByPane(panelId) != nil else { return .agentNotOwnedByPane }

        let sync = ClaudeTranscriptAccountSync()
        let request = ClaudeTranscriptAccountSyncRequest(
            sessionID: plan.sessionID,
            workingDirectory: plan.workingDirectory,
            sourceConfigDirectory: plan.sourceConfigDirectory,
            targetConfigDirectory: plan.targetConfigDirectory
        )
        let preflight: ClaudeTranscriptAccountSyncOutcome
        do {
            preflight = try await sync.sync(request)
        } catch {
            // A session nobody has sent a message to has nothing to resume, and the resume
            // would exit with "No conversation found", leaving the pane at a bare shell. Copies
            // that went on under both accounts are never overwritten.
            if let refusal = ClaudeAccountSwitchRefusal(
                transcriptSyncError: error,
                sourceAccountName: plan.source.name,
                targetAccountName: plan.target.name
            ) {
                return .refused(refusal)
            }
            return .transcriptUnavailable
        }

        // Checked again with the agents recorded now: they may have changed during the copy.
        guard let replacedAgents = claudeAccountSwitchAgentsOwnedByPane(panelId) else { return .agentNotOwnedByPane }
        let accountEnvironment = ClaudeAccountSwitchSurfaceEnvironment(
            plan: plan,
            workspaceEnvironment: workspaceEnvironment,
            processEnvironment: ProcessInfo.processInfo.environment
        )
        guard let panel = respawnTerminalSurface(
            panelId: panelId,
            command: nil,
            workingDirectory: plan.workingDirectory,
            environmentOverrides: accountEnvironment.overrides,
            removingEnvironmentKeys: accountEnvironment.removedKeys
        ) else {
            return .respawnFailed
        }
        // The pane keeps this account through later respawns and, via its snapshot, a relaunch.
        panel.claudeAccountEnvironment = ClaudeAccountPaneEnvironment(accountEnvironment)
        // Start the new shell now, even in a hidden pane, so its rc files run while the old
        // Claude exits. This is the start socket input gets, not the restore-paced one.
        panel.surface.requestInputDemandSurfaceStartIfNeeded()
        // The old Claude can append transcript lines until it dies; copy them before resuming.
        await Self.waitForReplacedClaudeProcessesToExit(replacedAgents.processes)
        let stillRunning = replacedAgents.stillRunning
        let outcome = await resyncClaudeAccountSwitchTranscript(sync, request, preflight: preflight)
        // A Claude that outlived the wait still owns the session: never start a second one.
        guard stillRunning.isEmpty else {
#if DEBUG
            cmuxDebugLog(
                "claudeAccount.switch panel=\(panelId.uuidString.prefix(5)) resume=skipped " +
                    "previousClaudeStillRunning=\(stillRunning.map(\.pid))"
            )
#endif
            return .switchedWithoutResume(plan, outcome, ClaudeAccountSwitchManualResume(
                command: resumeCommand,
                typedInput: resumeInput,
                reason: .previousClaudeStillRunning(processIDs: stillRunning.map(\.pid))
            ))
        }
        let delivery = await deliverClaudeAccountSwitchResumeInput(resumeInput, to: panel, panelId: panelId)
#if DEBUG
        cmuxDebugLog(
            "claudeAccount.switch panel=\(panelId.uuidString.prefix(5)) trigger=\(trigger) " +
                "from=\(plan.source.name) to=\(plan.target.name) transcript=\(outcome.rawValue) " +
                "resume=\(delivery)"
        )
#endif
        guard delivery != .typed else { return .switched(plan, outcome) }
        return .switchedWithoutResume(plan, outcome, ClaudeAccountSwitchManualResume(
            command: resumeCommand,
            typedInput: resumeInput,
            paneWasReplaced: delivery == .paneReplaced
        ))
    }

    /// Syncs the transcript again once the old Claude is gone, so lines it wrote after the
    /// preflight reach the target. A failed re-sync keeps the preflight copy, which is still
    /// resumable but may miss those last lines; it is logged, not reported.
    private func resyncClaudeAccountSwitchTranscript(
        _ sync: ClaudeTranscriptAccountSync,
        _ request: ClaudeTranscriptAccountSyncRequest,
        preflight: ClaudeTranscriptAccountSyncOutcome
    ) async -> ClaudeTranscriptAccountSyncOutcome {
        do {
            let resync = try await sync.sync(request)
            return preflight == .alreadyCurrent ? resync : preflight
        } catch {
#if DEBUG
            cmuxDebugLog("claudeAccount.switch resync.failed session=\(request.sessionID.prefix(8)) error=\(error)")
#endif
            return preflight
        }
    }

    /// The pane's recorded agent processes, or `nil` when restarting the pane would not stop one
    /// that is still running (see ``ClaudeAccountSwitchReplacedAgents/ownership(paneTTYDevice:)``).
    @MainActor
    private func claudeAccountSwitchAgentsOwnedByPane(_ panelId: UUID) -> ClaudeAccountSwitchReplacedAgents? {
        let agents = ClaudeAccountSwitchReplacedAgents(
            processes: (agentPIDKeysByPanelId[panelId] ?? []).compactMap { agentPIDProcessIdentitiesByKey[$0] }
        )
        let ownership = agents.ownership(
            paneTTYDevice: terminalPanel(for: panelId)?.surface.controllingTTYDeviceIdentifier
        )
        return ownership == .notOwnedByPane ? nil : agents
    }

    /// The pane's Claude session: the Fork Conversation selection, then cached lifecycle and
    /// agent-index state, then a fresh agent-index read when the cache is cold.
    @MainActor
    private func claudeAccountSwitchCandidateSnapshot(
        panelId: UUID
    ) async -> SessionRestorableAgentSnapshot? {
        if let selected = forkAgentConversationContextMenuOpenSelection(forPanelId: panelId).snapshot {
            return selected.kind == .claude ? selected : nil
        }
        if let cached = cachedClaudeAgentSnapshot(panelId: panelId) { return cached }
        guard terminalPanel(for: panelId) != nil,
              allowsAgentContinuation(forPanelId: panelId),
              let fresh = await SharedLiveAgentIndex.shared.indexRefreshingNow()?
                .exactEntry(workspaceId: id, panelId: panelId)?.snapshot else {
            return nil
        }
        return fresh.kind == .claude ? fresh : nil
    }

    /// The pane's Claude session from the in-process lifecycle record or the cached agent index.
    @MainActor
    private func cachedClaudeAgentSnapshot(panelId: UUID) -> SessionRestorableAgentSnapshot? {
        guard terminalPanel(for: panelId) != nil,
              allowsAgentContinuation(forPanelId: panelId) else {
            return nil
        }
        let snapshot = restoredAgentSnapshotForContinuation(panelId: panelId)
            ?? SharedLiveAgentIndex.shared.currentIndexSchedulingRefresh()?
                .exactEntry(workspaceId: id, panelId: panelId)?.snapshot
        return snapshot?.kind == .claude ? snapshot : nil
    }

    /// Waits for the replaced agent processes to exit, at most
    /// ``claudeAccountSwitchProcessExitTimeout``.
    private static func waitForReplacedClaudeProcessesToExit(
        _ processes: [AgentPIDProcessIdentity]
    ) async {
        guard !processes.isEmpty else { return }
        let terminations = processes.map {
            AgentHibernationController.ScopedProcessTermination(
                processID: Int($0.pid),
                processIdentity: $0,
                processGroupID: getpgid($0.pid)
            )
        }
        let timeout = claudeAccountSwitchProcessExitTimeout
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                _ = await AgentHibernationController.waitForExactProcessGenerationsToExitWithoutTimeout(
                    terminations
                )
            }
            group.addTask {
                // Genuine deadline: a process that outlives its terminal must not stall the switch.
                try? await ContinuousClock().sleep(for: timeout)
            }
            await group.next()
            group.cancelAll()
        }
    }
}
