import CMUXAgentLaunch
import CmuxSidebar
import Foundation

/// What ``SessionPriorityCoordinator`` reads from the live app: windows, Claude panes, the
/// restart gate's facts and the sidebar rows.
extension SessionPriorityCoordinator {
    /// The pane must go this long without input before it may be restarted.
    private static var quietInputWindowMs: Int64 {
        let (seconds, attoseconds) = SessionPriorityApplyGate.quietInputWindow.components
        return seconds * 1_000 + attoseconds / 1_000_000_000_000_000
    }

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
    /// (their session may be missing from the cache meanwhile), in sidebar order.
    func claudePanes(in workspace: Workspace) -> [ClaudePane] {
        workspace.orderedPanelIds.compactMap { panelId in
            let snapshot = workspace.sessionPriorityClaudeSnapshot(panelId: panelId)
            let restarting = Workspace.isSessionPriorityApplyInFlight(panelId: panelId)
                || state.records[panelId]?.awaitingSessionStartUntilMs != nil
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

    /// Whether the pane may be restarted now, read synchronously from the live pane.
    func paneVerdict(panelId: UUID, workspace: Workspace) -> SessionPriorityApplyGate.Verdict {
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
        return SessionPriorityApplyGate.evaluate(SessionPriorityApplyGate.Facts(
            responseRunning: workspace.isClaudeResponseRunning(panelId: panelId),
            receivedInputRecently: ClaudeAccountAutoSwitchCoordinator.shared.receivedInput(
                panelId: panelId,
                afterMs: Self.nowMs() - Self.quietInputWindowMs
            ),
            screen: screen,
            claudeInForeground: ClaudeAccountAutoSwitchForegroundCheck.claudeOwnsTerminal(
                registered: workspace.claudeAgentProcesses(panelId: panelId),
                startedAfter: .distantPast,
                paneTTYDevice: terminal.surface.controllingTTYDeviceIdentifier,
                facts: ClaudeAccountAutoSwitchForegroundCheck.liveFacts(pid:)
            ),
            accountSwitchInFlight: Workspace.isClaudeAccountSwitchInFlight(panelId: panelId),
            screenShowsManualChange: screenShowsManualChange
        ))
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
