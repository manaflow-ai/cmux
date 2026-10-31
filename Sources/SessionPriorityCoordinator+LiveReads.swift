import AppKit
import CMUXAgentLaunch
import CmuxSidebar
import Foundation

/// What ``SessionPriorityCoordinator`` reads from the live app: windows, Claude panes, the
/// restart gate's facts, the conversation transcript and the sidebar rows.
extension SessionPriorityCoordinator {
    static func tabManagers() -> [TabManager] {
        AppDelegate.shared?.mainWindowContexts.values.map(\.tabManager) ?? []
    }

    /// The window's Claude panes by workspace id. Dock panes are not counted.
    func claudePanes(in tabManager: TabManager) -> [UUID: [ClaudePane]] {
        var panes: [UUID: [ClaudePane]] = [:]
        for workspace in tabManager.tabs {
            let workspacePanes = claudePanes(in: workspace)
            if !workspacePanes.isEmpty { panes[workspace.id] = workspacePanes }
        }
        return panes
    }

    /// The workspace's panes that run Claude, and those a restart is moving to a new Claude
    /// (their session may be missing from the cache until the index shows the resumed Claude),
    /// in sidebar order.
    func claudePanes(in workspace: Workspace) -> [ClaudePane] {
        workspace.orderedPanelIds.compactMap { panelId in
            let snapshot = workspace.sessionPriorityClaudeSnapshot(panelId: panelId)
            let restarting = Workspace.isSessionPriorityApplyInFlight(panelId: panelId)
                || state.isRestarting(panelId: panelId, nowMs: Self.nowMs())
            guard snapshot != nil || restarting else { return nil }
            return ClaudePane(panelId: panelId, snapshot: snapshot)
        }
    }

    /// Whether cmux saw a `/effort` or `/model` on one of the workspace's panes.
    /// A cheap read of the pane records, for the sidebar menu's per-row snapshot
    /// (`snapshot(for:)` plans the whole window).
    func hasUserCommandOnScreen(in workspace: Workspace) -> Bool {
        workspace.orderedPanelIds.contains { state.records[$0]?.state == .manual(.userCommandOnScreen) }
    }

    /// The window's tiers and targets.
    static func plan(
        for tabManager: TabManager,
        panes: [UUID: [ClaudePane]],
        urgentCount: Int,
        matrix: SessionPriorityMatrix
    ) -> [UUID: SessionPriorityPlan.Entry] {
        var inputs: [UUID: SessionPriorityPlan.WorkspaceInput] = [:]
        for workspace in tabManager.tabs {
            let priority = workspace.sessionPriorityState
            inputs[workspace.id] = SessionPriorityPlan.WorkspaceInput(
                id: workspace.id,
                hasClaudePane: panes[workspace.id]?.isEmpty == false,
                difficulty: priority.effectiveDifficulty,
                difficultySource: priority.difficultySource,
                isManual: priority.isManual
            )
        }
        return SessionPriorityPlan.make(
            effectiveOrder: tabManager.sessionPriorityEffectiveOrder,
            workspaces: inputs,
            urgentCount: urgentCount,
            matrix: matrix
        )
    }

    /// Whether the pane may be restarted now for `target`, read synchronously from the live pane
    /// and the workspace.
    func paneVerdict(
        panelId: UUID,
        workspace: Workspace,
        target: SessionPriorityTarget
    ) -> SessionPriorityApplyGate.Verdict {
        guard isEnabled else { return .hold(.disabled) }
        guard let terminal = workspace.terminalPanel(for: panelId) else { return .hold(.unknownScreen) }
        let screen: ClaudeAccountAutoSwitchContinueGate.Screen
        if let frame = terminal.surface.mobileRenderGridFrame(stateSeq: 0, includeTheme: false, anchor: .screen)?.frame {
            screen = ClaudeAccountAutoSwitchContinueGate.Screen(frame: frame)
        } else {
            screen = ClaudeAccountAutoSwitchContinueGate.Screen(state: .unknown, showsInterruptHint: false)
        }
        // A `/effort` typed while the pane waited in the queue, longer ago than the quiet window.
        let markers = SessionPriorityCoordinatorState.screenMarkerCount(in: terminal.surface.visibleText() ?? "")
        let screenShowsManualChange = state.records[panelId]?.stickyManual != nil
            || state.showsUndismissedManualMarker(panelId: panelId, markerCount: markers)
        let receivedInputRecently = SessionPriorityApplyGate.isInsideQuietWindow(
            nowMs: Self.nowMs(),
            receivedInputAfter: { ClaudeAccountAutoSwitchCoordinator.shared.receivedInput(panelId: panelId, afterMs: $0) },
            lastTurnEndMs: state.lastTurnEndedAtMs[panelId]
        )
        return SessionPriorityApplyGate.evaluate(SessionPriorityApplyGate.Facts(
            responseRunning: workspace.isClaudeResponseRunning(panelId: panelId),
            receivedInputRecently: receivedInputRecently,
            screen: screen,
            claudeInForeground: ClaudeAccountAutoSwitchForegroundCheck.claudeOwnsTerminal(
                registered: workspace.claudeAgentProcesses(panelId: panelId),
                startedAfter: .distantPast,
                paneTTYDevice: terminal.surface.controllingTTYDeviceIdentifier,
                facts: ClaudeAccountAutoSwitchForegroundCheck.liveFacts(pid:)
            ),
            accountSwitchInFlight: Workspace.isClaudeAccountSwitchInFlight(panelId: panelId),
            screenShowsManualChange: screenShowsManualChange,
            workspaceMarkedManual: workspace.sessionPriorityState.isManual,
            targetIsCurrent: currentTarget(of: workspace) == target,
            backgroundWorkPending: Self.claudeBackgroundWorkPending(panelId: panelId, in: workspace)
                || state.hasPendingBackgroundWork(panelId: panelId),
            paneIsFocused: Self.isFocusedPaneOfKeyWindow(panelId: panelId, workspaceId: workspace.id)
        ))
    }

    /// What the workspace's tier and difficulty ask for now, from the live rank; `nil` while
    /// the workspace is manual or has left the plan.
    private func currentTarget(of workspace: Workspace) -> SessionPriorityTarget? {
        guard let tabManager = AppDelegate.shared?.tabManagerFor(tabId: workspace.id) else { return nil }
        let settings = Settings.current()
        return Self.plan(
            for: tabManager,
            panes: claudePanes(in: tabManager),
            urgentCount: settings.urgentCount,
            matrix: .fromStoredString(settings.matrix)
        )[workspace.id]?.target
    }

    /// Whether the pane's Claude ended its last turn with background work still running, as
    /// its journal lifecycle reports it: the same `pending_work` an account switch holds back
    /// for (`ClaudeAccountAutoSwitchRequest`), projected onto the sidebar's lifecycle state.
    /// The gate also reads the coordinator's own record of that turn end
    /// (``SessionPriorityCoordinatorState/hasPendingBackgroundWork(panelId:)``), which a later
    /// `SubagentStop` projected as running does not clear.
    static func claudeBackgroundWorkPending(panelId: UUID, in workspace: Workspace) -> Bool {
        workspace.agentLifecycleStatesByPanelId[panelId]?[Workspace.claudeAgentLifecycleKey] == .backgroundWorkPending
    }

    /// Whether the pane is the one the user types into: the focused surface of the selected
    /// workspace of the key main window, while cmux is the active app (the same reading
    /// notifications use for "the surface the user is looking at").
    static func isFocusedPaneOfKeyWindow(panelId: UUID, workspaceId: UUID) -> Bool {
        guard AppFocusState.isAppFocused(),
              let keyWindow = NSApp.keyWindow,
              let tabManager = AppDelegate.shared?.contextForMainTerminalWindow(keyWindow, reindex: false)?.tabManager,
              tabManager.selectedTabId == workspaceId else { return false }
        return tabManager.focusedSurfaceId(for: workspaceId) == panelId
    }

    /// Whether the pane's transcript records a `/effort` or `/model` the user ran after the
    /// pane's dismissal time (cmux's last restart of it, or "Adjust Claude Effort
    /// Automatically"). Read off the main actor; a transcript that cannot be read counts as none.
    func userChangedEffortInTranscript(panelId: UUID, workspace: Workspace) async -> Bool {
        guard let snapshot = workspace.sessionPriorityClaudeSnapshot(panelId: panelId),
              let workingDirectory = snapshot.workingDirectory ?? snapshot.launchCommand?.workingDirectory
        else { return false }
        let sessionID = snapshot.sessionId
        let configDirectory = Workspace.sessionPriorityConfigDirectory(launchEnvironment: snapshot.launchCommand?.environment)
        let dismissedAt = state.manualDismissedAtMs[panelId].map {
            Date(timeIntervalSince1970: TimeInterval($0) / 1_000)
        } ?? .distantPast
        return await Task.detached {
            guard let path = ClaudeTranscriptConversationLocator.transcriptPath(
                sessionID: sessionID,
                workingDirectory: workingDirectory,
                configDirectory: configDirectory
            ) else { return false }
            do {
                return try ClaudeTranscriptLocalCommandProbe.lastEffortOrModelChange(
                    transcriptPath: path,
                    after: dismissedAt
                ) != nil
            } catch {
#if DEBUG
                cmuxDebugLog("sessionPriority probe.localCommand.failed session=\(sessionID.prefix(8)) error=\(error)")
#endif
                return false
            }
        }.value
    }

    // MARK: - Rows

    /// Shows `entry` as the workspace's row, unless the row already reads the same.
    static func showRow(_ entry: SidebarStatusEntry, in workspace: Workspace) {
        let key = SessionPriorityStatusRow.key
        if let shown = workspace.statusEntries[key], shown.value == entry.value, shown.icon == entry.icon,
           shown.color == entry.color, shown.priority == entry.priority {
            return
        }
        workspace.setStatusEntry(entry, key: key, panelId: nil)
    }

    static func removeRow(from workspace: Workspace) {
        guard workspace.statusEntries[SessionPriorityStatusRow.key] != nil else { return }
        workspace.removeStatusEntry(forKey: SessionPriorityStatusRow.key)
    }

    /// Removes the row from every workspace that shows it: those in `shown`, and any other one
    /// that still does.
    func removeRows(also shown: Set<UUID>) {
        for tabManager in Self.tabManagers() {
            for workspace in tabManager.tabs
            where shown.contains(workspace.id) || workspace.statusEntries[SessionPriorityStatusRow.key] != nil {
                Self.removeRow(from: workspace)
            }
        }
    }
}
