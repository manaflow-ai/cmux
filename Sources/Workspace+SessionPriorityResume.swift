import CMUXAgentLaunch
import CmuxFoundation
import CmuxTerminal
import Darwin
import Foundation

extension Workspace {
    /// Panes with a session priority restart in flight. Keyed by panel id across workspaces
    /// because a pane keeps its id when it moves.
    @MainActor private static var sessionPriorityApplyInFlightPanelIds: Set<UUID> = []

    /// Upper bound on waiting for the replaced Claude process to exit. A Claude still running
    /// after it gets no resume typed.
    private static let sessionPriorityProcessExitTimeout: Duration = .seconds(3)

    /// Whether a session priority restart of the pane is in progress.
    @MainActor
    static func isSessionPriorityApplyInFlight(panelId: UUID) -> Bool {
        sessionPriorityApplyInFlightPanelIds.contains(panelId)
    }

    // Mirrors PR1's private `cachedClaudeAgentSnapshot(panelId:)`.
    /// The pane's Claude session from the in-process lifecycle record or the cached agent index.
    /// Reads cached state only, so it may lag a just-started session.
    @MainActor
    func sessionPriorityClaudeSnapshot(panelId: UUID) -> SessionRestorableAgentSnapshot? {
        guard terminalPanel(for: panelId) != nil,
              allowsAgentContinuation(forPanelId: panelId) else {
            return nil
        }
        let snapshot = restoredAgentSnapshotForContinuation(panelId: panelId)
            ?? SharedLiveAgentIndex.shared.currentIndexSchedulingRefresh()?
                .exactEntry(workspaceId: id, panelId: panelId)?.snapshot
        return snapshot?.kind == .claude ? snapshot : nil
    }

    /// Restarts the pane's Claude between turns with `target` applied, resuming the same session.
    ///
    /// The surface respawns with its environment untouched and the new shell gets
    /// `cd <dir> && CLAUDE_CODE_EFFORT_LEVEL=<level> claude --resume <id> [--model <model>]`
    /// (see ``SessionPriorityResumeInput``), typed only once it reports a prompt on an untouched
    /// line. Every refusal and hold happens before the pane changes. A Claude the restart would
    /// not stop is refused; one that outlives the restart gets no resume typed and the command
    /// comes back in ``SessionPriorityApplyResult/resumeNotTyped(_:)``.
    ///
    /// - Parameter paneIsFree: Asked synchronously before the slow checks, and again right before
    ///   the restart, after every await. A hold leaves the pane alone and comes back as
    ///   ``SessionPriorityApplyResult/held(_:)``.
    @MainActor
    func applySessionPriority(
        panelId: UUID,
        target: SessionPriorityTarget,
        paneIsFree: @MainActor () -> SessionPriorityApplyGate.Verdict
    ) async -> SessionPriorityApplyResult {
        guard Self.sessionPriorityApplyInFlightPanelIds.insert(panelId).inserted else {
            return .refused(.alreadyApplying)
        }
        defer { Self.sessionPriorityApplyInFlightPanelIds.remove(panelId) }
        let result = await restartClaudeForSessionPriority(panelId: panelId, target: target, paneIsFree: paneIsFree)
#if DEBUG
        cmuxDebugLog(
            "sessionPriority.apply panel=\(panelId.uuidString.prefix(5)) " +
                "effort=\(target.effort?.rawValue ?? "-") model=\(target.model ?? "-") " +
                "result=\(result.debugSummary)"
        )
#endif
        return result
    }

    /// The restart sequence behind ``applySessionPriority(panelId:target:paneIsFree:)``.
    @MainActor
    private func restartClaudeForSessionPriority(
        panelId: UUID,
        target: SessionPriorityTarget,
        paneIsFree: @MainActor () -> SessionPriorityApplyGate.Verdict
    ) async -> SessionPriorityApplyResult {
        guard !Self.isClaudeAccountSwitchInFlight(panelId: panelId) else { return .held(.accountSwitchInFlight) }
        guard let candidate = sessionPriorityClaudeSnapshot(panelId: panelId) else { return .refused(.notClaude) }
        guard !terminalRunsOnAnotherMachine(panelId) else { return .refused(.remoteUnsupported) }
        // The cheap gate before the slow checks, so a busy pane costs no process scan or read.
        if case .hold(let reason) = paneIsFree() { return .held(reason) }
        // A session cmux cannot confirm as the pane's live one would resume the wrong conversation.
        guard let snapshot = await authoritativeForkSnapshot(
            selected: candidate,
            panelId: panelId,
            isRemoteContext: false
        ) else {
            return .refused(.noClaudeSession)
        }
        guard let workingDirectory = snapshot.workingDirectory ?? snapshot.launchCommand?.workingDirectory else {
            return .refused(.missingWorkingDirectory)
        }
        // A session nobody has sent a message to has nothing to resume: the resume would exit with
        // "No conversation found" and leave the pane at a bare shell.
        guard await Self.sessionPriorityHasConversation(snapshot, workingDirectory: workingDirectory) else {
            return .refused(.noConversationYet)
        }
        // Built before anything changes, so an unresumable session never costs the pane its agent.
        // The pane keeps the account an earlier switch gave it, even where rc files re-export a key.
        let resume = SessionPriorityResumeInput(
            snapshot: snapshot,
            target: target,
            workingDirectory: workingDirectory,
            clearedEnvironmentKeys: terminalPanel(for: panelId)?.claudeAccountEnvironment?.clearedKeys ?? []
        )
        guard let resumeCommand = resume.posixCommand(), let resumeInput = resume.typedInput() else {
            return .refused(.noClaudeSession)
        }
        // Restarting the pane stops only a Claude on the pane's own terminal; one in tmux or
        // detached would keep writing this session while the resumed Claude continues it.
        let replacedAgents = ClaudeAccountSwitchReplacedAgents(
            processes: (agentPIDKeysByPanelId[panelId] ?? []).compactMap { agentPIDProcessIdentitiesByKey[$0] }
        )
        let ownership = replacedAgents.ownership(
            paneTTYDevice: terminalPanel(for: panelId)?.surface.controllingTTYDeviceIdentifier
        )
        guard ownership != .notOwnedByPane else { return .refused(.agentNotOwnedByPane) }
        // No await from here to the restart, so what the user did meanwhile is seen. An account
        // switch may have started during the awaits above; it owns the pane's restart.
        guard !Self.isClaudeAccountSwitchInFlight(panelId: panelId) else { return .held(.accountSwitchInFlight) }
        if case .hold(let reason) = paneIsFree() { return .held(reason) }
        // No environment change: the pane keeps its account and every other key it had.
        guard let panel = respawnTerminalSurface(
            panelId: panelId,
            command: nil,
            workingDirectory: workingDirectory,
            environmentOverrides: [:],
            removingEnvironmentKeys: []
        ) else {
            return .respawnFailed
        }
        // Start the new shell now, even in a hidden pane, so its rc files run while the old
        // Claude exits. This is the start socket input gets, not the restore-paced one.
        panel.surface.requestInputDemandSurfaceStartIfNeeded()
        await Self.waitForSessionPriorityReplacedProcessesToExit(replacedAgents.processes)
        // A Claude that outlived the wait still owns the session: never start a second one.
        let stillRunning = replacedAgents.stillRunning
        guard stillRunning.isEmpty else {
            return .resumeNotTyped(ClaudeAccountSwitchManualResume(
                command: resumeCommand,
                typedInput: resumeInput,
                reason: .previousClaudeStillRunning(processIDs: stillRunning.map(\.pid))
            ))
        }
        let delivery = await deliverClaudeAccountSwitchResumeInput(
            resumeInput,
            to: panel,
            panelId: panelId,
            // Unattended: never type over input that reached the new shell first.
            requiresUntouchedShellLine: true
        )
        guard delivery != .typed else { return .applied(sessionID: snapshot.sessionId) }
        return .resumeNotTyped(ClaudeAccountSwitchManualResume(
            command: resumeCommand,
            typedInput: resumeInput,
            paneWasReplaced: delivery == .paneReplaced
        ))
    }

    /// The Claude config directory the session's transcript lives under: the recorded
    /// `CLAUDE_CONFIG_DIR`, or `~/.claude` when it is unset, empty or blank.
    nonisolated static func sessionPriorityConfigDirectory(
        launchEnvironment: [String: String]?,
        homeDirectory: String = NSHomeDirectory()
    ) -> String {
        guard let recorded = launchEnvironment?["CLAUDE_CONFIG_DIR"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !recorded.isEmpty else {
            return (homeDirectory as NSString).appendingPathComponent(".claude")
        }
        return ClaudeConfigDirectoryPath.preferredPath(recorded, homeDirectory: homeDirectory)
    }

    /// Whether the session's transcript holds a conversation, read off the main actor. An
    /// unreadable transcript counts as none.
    private static func sessionPriorityHasConversation(
        _ snapshot: SessionRestorableAgentSnapshot,
        workingDirectory: String
    ) async -> Bool {
        let sessionID = snapshot.sessionId
        let configDirectory = sessionPriorityConfigDirectory(launchEnvironment: snapshot.launchCommand?.environment)
        return await Task.detached {
            do {
                return try ClaudeTranscriptConversationLocator.hasConversation(
                    sessionID: sessionID,
                    workingDirectory: workingDirectory,
                    configDirectory: configDirectory
                )
            } catch {
#if DEBUG
                cmuxDebugLog("sessionPriority.apply probe.failed session=\(sessionID.prefix(8)) error=\(error)")
#endif
                return false
            }
        }.value
    }

    // Mirrors PR1's private `waitForReplacedClaudeProcessesToExit(_:)`.
    /// Waits for the replaced agent processes to exit, at most
    /// ``sessionPriorityProcessExitTimeout``.
    private static func waitForSessionPriorityReplacedProcessesToExit(
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
        let timeout = sessionPriorityProcessExitTimeout
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                _ = await AgentHibernationController.waitForExactProcessGenerationsToExitWithoutTimeout(
                    terminations
                )
            }
            group.addTask {
                // Genuine deadline: a process that outlives its terminal must not stall the restart.
                try? await ContinuousClock().sleep(for: timeout)
            }
            await group.next()
            group.cancelAll()
        }
    }
}
