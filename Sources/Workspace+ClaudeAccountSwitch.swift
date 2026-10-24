import CMUXAgentLaunch
import CmuxFoundation
import Darwin
import Foundation

extension Workspace {
    /// Panes with a switch in flight. Keyed by panel id across workspaces because a pane keeps
    /// its id when it moves, and a second switch must still see the first one.
    @MainActor private static var claudeAccountSwitchInFlightPanelIds: Set<UUID> = []

    /// Upper bound on waiting for the replaced Claude process to exit before the re-sync.
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

    /// Moves the pane's Claude session to another registered account and resumes it there.
    ///
    /// The transcript is copied into the target account first; if that fails the pane is left
    /// alone, so a switch never starts a fresh conversation. The surface then respawns with the
    /// target's account keys (see ``ClaudeAccountSwitchSurfaceEnvironment``), the transcript is
    /// synced again once the old Claude has exited, and `claude --resume` is typed into the new
    /// shell. Remote panes are refused. Confirming a running turn is the caller's job; this
    /// never asks.
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
        guard let resumeInput = ClaudeAccountSwitchResumeInput(snapshot: snapshot, plan: plan).typedInput() else {
            return .refused(.noClaudeSession)
        }

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
            return .transcriptUnavailable
        }

        let replacedProcesses = (agentPIDKeysByPanelId[panelId] ?? []).compactMap {
            agentPIDProcessIdentitiesByKey[$0]
        }
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
        // The old Claude can append transcript lines until it dies; copy them before resuming.
        // A failed re-sync keeps the preflight copy, which is still resumable.
        await Self.waitForReplacedClaudeProcessesToExit(replacedProcesses)
        let resync = try? await sync.sync(request)
        if terminalPanel(for: panelId) === panel {
            sendInputWhenReady(resumeInput, to: panel)
        }

        let outcome = preflight == .alreadyCurrent ? (resync ?? preflight) : preflight
#if DEBUG
        cmuxDebugLog(
            "claudeAccount.switch panel=\(panelId.uuidString.prefix(5)) trigger=\(trigger) " +
                "from=\(plan.source.name) to=\(plan.target.name) transcript=\(outcome.rawValue)"
        )
#endif
        return .switched(plan, outcome)
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
