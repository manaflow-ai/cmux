import CmuxControlSocket
import CmuxRemoteSession
import Foundation
import CmuxWorkspaces
import CmuxSidebar

/// The live-app half of the v1 sidebar telemetry/report commands
/// (`report_git_branch` / `report_pr` / `report_ports` / `report_pwd` /
/// `report_shell_state` / `report_tty` / `ports_kick` / `sidebar_state` /
/// `reset_sidebar` / `right_sidebar`): the exact mutation/read bodies the
/// former `TerminalController` v1 handlers ran.
extension TerminalController {
    // MARK: - Git branch

    /// All scoped schedulers below enqueue with a replace key: the worker
    /// lane replies before main drains, so a client can keep reporting while
    /// the main actor is blocked. Last-write-wins coalescing per
    /// (workspace, panel, kind) bounds `TerminalMutationBus.pending` at one
    /// entry per key instead of growing per report. The unscoped fallback
    /// paths stay non-coalesced: they resolve their target at drain time and
    /// serve manual invocations, not shell-integration hot loops.
    nonisolated func controlSidebarScheduleScopedGitBranchUpdate(
        scope: ControlSidebarPanelScope,
        branch: String,
        isDirty: Bool?
    ) {
        TerminalMutationBus.shared.enqueueReplacingMainActorMutation(
            replaceKey: TerminalMutationReplaceKey(
                tabId: scope.workspaceID,
                surfaceId: scope.panelID,
                kind: .gitBranch
            )
        ) { [weak self] in
            guard let self,
                  let (tabManager, tab) = self.controlSidebarResolveScopedPanel(scope: scope) else {
                return
            }
            let validSurfaceIds = Set(tab.panels.keys)
            tab.pruneSurfaceMetadata(validSurfaceIds: validSurfaceIds)
            guard validSurfaceIds.contains(scope.panelID) else { return }
            guard SidebarWorkspaceDetailDefaults.watchGitStatusValue(defaults: .standard) else {
                tabManager.clearSurfaceGitBranch(tabId: tab.id, surfaceId: scope.panelID)
                return
            }
            tabManager.updateSurfaceGitBranch(
                tabId: tab.id,
                surfaceId: scope.panelID,
                branch: branch,
                isDirty: isDirty
            )
        }
    }

    func controlSidebarUpdateGitBranch(tabArg: String?, branch: String, isDirty: Bool?) -> Bool {
        guard let tab = controlSidebarResolveTabForReport(tabArg: tabArg) else {
            return false
        }
        guard SidebarWorkspaceDetailDefaults.watchGitStatusValue(defaults: .standard) else {
            tab.gitBranch = nil
            return true
        }
        let existingGitBranch = tab.gitBranch
        let nextIsDirty = isDirty ?? (existingGitBranch?.branch == branch ? existingGitBranch?.isDirty ?? false : false)
        tab.gitBranch = SidebarGitBranchState(
            branch: branch,
            isDirty: nextIsDirty
        )
        return true
    }

    /// Shares `.gitBranch` with the update scheduler: update-then-clear (or
    /// clear-then-update) coalesces to the newest write, matching what the
    /// serialized path leaves as the final state.
    nonisolated func controlSidebarScheduleScopedGitBranchClear(scope: ControlSidebarPanelScope) {
        TerminalMutationBus.shared.enqueueReplacingMainActorMutation(
            replaceKey: TerminalMutationReplaceKey(
                tabId: scope.workspaceID,
                surfaceId: scope.panelID,
                kind: .gitBranch
            )
        ) { [weak self] in
            guard let self,
                  let (tabManager, tab) = self.controlSidebarResolveScopedPanel(scope: scope) else {
                return
            }
            let validSurfaceIds = Set(tab.panels.keys)
            tab.pruneSurfaceMetadata(validSurfaceIds: validSurfaceIds)
            guard validSurfaceIds.contains(scope.panelID) else { return }
            tabManager.clearSurfaceGitBranch(tabId: tab.id, surfaceId: scope.panelID)
        }
    }

    func controlSidebarClearGitBranch(tabArg: String?) -> Bool {
        guard let tab = controlSidebarResolveTabForReport(tabArg: tabArg) else {
            return false
        }
        tab.gitBranch = nil
        return true
    }

    // MARK: - Pull requests (panel metadata mutations)

    nonisolated func controlSidebarIsValidPullRequestState(_ raw: String) -> Bool {
        SidebarPullRequestStatus(rawValue: raw) != nil
    }

    /// PR metadata mutations intentionally do NOT coalesce:
    /// `shouldReplacePullRequest` applies an ordering guard against the state
    /// current at drain, so collapsing an update chain to its newest entry
    /// could drop an intermediate update the guard would have accepted. The
    /// traffic is poller-cadence, not per-prompt, so unbounded growth is not
    /// a practical concern on this path.
    nonisolated func controlSidebarSchedulePanelPullRequestUpdate(
        target: ControlSidebarPanelMutationTarget,
        number: Int,
        label: String,
        url: URL,
        statusRawValue: String,
        branch: String?
    ) {
        guard let status = SidebarPullRequestStatus(rawValue: statusRawValue) else {
            // Unreachable: the coordinator validates the state first.
            return
        }
        controlSidebarSchedulePanelMetadataMutation(target: target) { tab, surfaceId in
            guard SidebarWorkspaceDetailDefaults.pullRequestPollingEnabled(defaults: .standard) else {
                tab.clearPanelPullRequest(panelId: surfaceId)
                return
            }

            guard Self.shouldReplacePullRequest(
                current: tab.panelPullRequests[surfaceId],
                number: number,
                label: label,
                url: url,
                status: status,
                branch: branch
            ) else {
                return
            }

            tab.updatePanelPullRequest(
                panelId: surfaceId,
                number: number,
                label: label,
                url: url,
                status: status,
                branch: branch
            )
        }
    }

    nonisolated func controlSidebarSchedulePanelPullRequestClear(target: ControlSidebarPanelMutationTarget) {
        controlSidebarSchedulePanelMetadataMutation(target: target) { tab, surfaceId in
            tab.clearPanelPullRequest(panelId: surfaceId)
        }
    }

    nonisolated func controlSidebarSchedulePanelPullRequestAction(
        target: ControlSidebarPanelMutationTarget,
        action: String,
        actionTarget: String?
    ) {
        controlSidebarSchedulePanelMetadataMutation(target: target) { tab, surfaceId in
            guard SidebarWorkspaceDetailDefaults.pullRequestPollingEnabled(defaults: .standard) else {
                tab.clearPanelPullRequest(panelId: surfaceId)
                return
            }

            guard let tabManager = AppDelegate.shared?.tabManagerFor(tabId: tab.id) else { return }
            tabManager.handleWorkspacePullRequestCommandHint(
                tabId: tab.id,
                surfaceId: surfaceId,
                action: action,
                target: actionTarget
            )
        }
    }

    // MARK: - Ports / pwd / shell state / tty / kick

    func controlSidebarSetPorts(tabArg: String?, panelArg: String?, ports: [Int]) -> ControlSidebarPanelWriteResolution {
        controlSidebarResolvePanelWrite(
            tabArg: tabArg,
            panelArg: panelArg,
            prune: true,
            requireLiveSurface: true
        ) { tab, surfaceId in
            tab.surfaceListeningPorts[surfaceId] = ports
            tab.recomputeListeningPorts()
        }
    }

    func controlSidebarClearPorts(tabArg: String?, panelArg: String?) -> ControlSidebarPanelWriteResolution {
        if panelArg != nil {
            return controlSidebarResolvePanelWrite(
                tabArg: tabArg,
                panelArg: panelArg,
                prune: true,
                requireLiveSurface: true
            ) { tab, surfaceId in
                tab.surfaceListeningPorts.removeValue(forKey: surfaceId)
                tab.recomputeListeningPorts()
            }
        }

        guard let tab = controlSidebarResolveTabForReport(tabArg: tabArg) else {
            return .tabNotFound
        }

        let validSurfaceIds = Set(tab.panels.keys)
        tab.pruneSurfaceMetadata(validSurfaceIds: validSurfaceIds)
        tab.surfaceListeningPorts.removeAll()
        tab.recomputeListeningPorts()
        return .done
    }

    /// The dedupe compare-and-set runs at DRAIN time, inside the enqueued
    /// main-actor closure, not at enqueue time on the worker: this witness is
    /// called from per-connection socket-worker threads, and a gate taken
    /// before the enqueue could record two connections' states for the same
    /// surface in one order but enqueue them in the other, leaving the
    /// applied model state disagreeing with the dedupe cache until the next
    /// running/prompt cycle. Recording where the bus drains keeps record
    /// order identical to apply order, as the serialized pre-worker-lane
    /// path guaranteed.
    ///
    /// Boundedness: the worker lane replies without waiting for main, so a
    /// client can keep reporting while the main actor is blocked and unable
    /// to drain. The replace-key enqueue below keeps at most ONE pending
    /// shell-state mutation per (workspace, panel) — a fresh report replaces
    /// the superseded pending one (last-write-wins; only the final state is
    /// observable once main unblocks). This is a strictly tighter bound than
    /// the pre-worker-lane path, which enqueued every state CHANGE. The CAS
    /// at drain time stays authoritative for publish/skip.
    nonisolated func controlSidebarScheduleScopedShellState(scope: ControlSidebarPanelScope, stateRawValue: String) {
        guard let state = PanelShellActivityState(rawValue: stateRawValue) else {
            // Unreachable: the coordinator only forwards a value this app produced.
            return
        }
        let fastPathState = socketFastPathState
        TerminalMutationBus.shared.enqueueReplacingMainActorMutation(
            replaceKey: TerminalMutationReplaceKey(
                tabId: scope.workspaceID,
                surfaceId: scope.panelID,
                kind: .shellActivity
            )
        ) { [weak self] in
            guard let self,
                  let (tabManager, tab) = self.controlSidebarResolveScopedPanel(scope: scope) else {
                return
            }
            guard fastPathState.shouldPublishShellActivity(
                workspaceId: tab.id,
                panelId: scope.panelID,
                state: state.rawValue
            ) else {
                return
            }
            tabManager.updateSurfaceShellActivity(tabId: tab.id, surfaceId: scope.panelID, state: state)
        }
    }

    func controlSidebarUpdateShellState(tabArg: String?, panelArg: String?, stateRawValue: String) -> ControlSidebarPanelWriteResolution {
        guard let state = PanelShellActivityState(rawValue: stateRawValue) else {
            // Unreachable: the coordinator only forwards a value this app produced.
            return .tabNotFound
        }
        return controlSidebarResolvePanelWrite(
            tabArg: tabArg,
            panelArg: panelArg,
            prune: true,
            requireLiveSurface: true
        ) { tab, surfaceId in
            guard let tabManager = controlSidebarTabManager(for: tab) else { return }
            tabManager.updateSurfaceShellActivity(tabId: tab.id, surfaceId: surfaceId, state: state)
        }
    }

    /// Deliberately NOT coalesced: a scoped `ports_kick` queued after a TTY
    /// report must drain after the registration (`PortScanner.kick` no-ops
    /// for unregistered TTYs), and replace-key coalescing would let a
    /// repeated report jump behind an already-queued kick. `report_tty`
    /// fires once per shell start, not per prompt, so unbounded growth is
    /// not a practical concern on this path.
    nonisolated func controlSidebarScheduleScopedTTY(scope: ControlSidebarPanelScope, ttyName: String) {
        TerminalMutationBus.shared.enqueueMainActorMutation { [weak self] in
            guard let self,
                  let (_, tab) = self.controlSidebarResolveScopedPanel(scope: scope) else {
                return
            }
            let validSurfaceIds = Set(tab.panels.keys)
            tab.pruneSurfaceMetadata(validSurfaceIds: validSurfaceIds)
            guard validSurfaceIds.contains(scope.panelID) else { return }
            tab.surfaceTTYNames[scope.panelID] = ttyName
            if tab.isRemoteWorkspace {
                tab.syncRemotePortScanTTYs()
                _ = tab.applyPendingRemoteSurfacePortKickIfNeeded(to: scope.panelID)
            } else {
                PortScanner.shared.registerTTY(workspaceId: tab.id, panelId: scope.panelID, ttyName: ttyName)
            }
        }
    }

    func controlSidebarReportTTY(tabArg: String?, panelArg: String?, ttyName: String) -> ControlSidebarPanelWriteResolution {
        controlSidebarResolvePanelWrite(
            tabArg: tabArg,
            panelArg: panelArg,
            prune: false,
            requireLiveSurface: true
        ) { tab, surfaceId in
            tab.surfaceTTYNames[surfaceId] = ttyName
            if tab.isRemoteWorkspace {
                tab.syncRemotePortScanTTYs()
                _ = tab.applyPendingRemoteSurfacePortKickIfNeeded(to: surfaceId)
            } else {
                PortScanner.shared.registerTTY(workspaceId: tab.id, panelId: surfaceId, ttyName: ttyName)
            }
        }
    }

    nonisolated func controlSidebarScheduleScopedPortsKick(scope: ControlSidebarPanelScope, reasonRawValue: String) {
        guard let reason = PortScanKickReason(rawValue: reasonRawValue) else {
            // Unreachable: the coordinator only forwards a value this app produced.
            return
        }
        // Keyed by reason: a kick is an idempotent rescan trigger, so
        // same-reason duplicates collapse while distinct reasons each run.
        TerminalMutationBus.shared.enqueueReplacingMainActorMutation(
            replaceKey: TerminalMutationReplaceKey(
                tabId: scope.workspaceID,
                surfaceId: scope.panelID,
                kind: .portsKick(reason)
            )
        ) { [weak self] in
            guard let self,
                  let (_, tab) = self.controlSidebarResolveScopedPanel(scope: scope) else {
                return
            }
            let validSurfaceIds = Set(tab.panels.keys)
            tab.pruneSurfaceMetadata(validSurfaceIds: validSurfaceIds)
            guard validSurfaceIds.contains(scope.panelID) else { return }
            if tab.isRemoteWorkspace {
                tab.kickRemotePortScan(panelId: scope.panelID, reason: reason)
            } else {
                PortScanner.shared.kick(workspaceId: tab.id, panelId: scope.panelID)
            }
        }
    }

    func controlSidebarPortsKick(tabArg: String?, panelArg: String?, reasonRawValue: String) -> ControlSidebarPanelWriteResolution {
        guard let reason = PortScanKickReason(rawValue: reasonRawValue) else {
            // Unreachable: the coordinator only forwards a value this app produced.
            return .tabNotFound
        }
        return controlSidebarResolvePanelWrite(
            tabArg: tabArg,
            panelArg: panelArg,
            prune: false,
            requireLiveSurface: false
        ) { tab, surfaceId in
            if tab.isRemoteWorkspace {
                tab.kickRemotePortScan(panelId: surfaceId, reason: reason)
            } else {
                PortScanner.shared.kick(workspaceId: tab.id, panelId: surfaceId)
            }
        }
    }

    // MARK: - State / reset / right sidebar

    func controlSidebarStateSnapshot(tabArg: String?) -> ControlSidebarStateSnapshot? {
        guard let tab = controlSidebarResolveTabForReport(tabArg: tabArg) else { return nil }

        let focusedPanel: ControlSidebarFocusedPanelInfo?
        if let focused = tab.focusedPanelId,
           let focusedDir = tab.reportedPanelDirectory(panelId: focused) {
            focusedPanel = ControlSidebarFocusedPanelInfo(panelID: focused, directory: focusedDir)
        } else {
            focusedPanel = nil
        }

        let gitBranch = tab.presentedGitBranch.map {
            ControlSidebarGitBranchInfo(branch: $0.branch, isDirty: $0.isDirty)
        }

        let firstPullRequest = tab.sidebarPullRequestsInDisplayOrder().first.map {
            ControlSidebarPullRequestInfo(
                number: $0.number,
                statusRawValue: $0.status.rawValue,
                urlAbsoluteString: $0.url.absoluteString,
                label: $0.label
            )
        }

        let progress = tab.progress.map {
            ControlSidebarProgressInfo(value: $0.value, label: $0.label)
        }

        return ControlSidebarStateSnapshot(
            tabID: tab.id,
            customColor: tab.customColor,
            currentDirectory: tab.presentedCurrentDirectory ?? "",
            focusedPanel: focusedPanel,
            gitBranch: gitBranch,
            firstPullRequest: firstPullRequest,
            listeningPorts: tab.listeningPorts,
            progress: progress,
            statusEntries: tab.sidebarStatusEntriesInDisplayOrder().map {
                ControlSidebarStatusEntrySnapshot(
                    key: $0.key,
                    value: $0.value,
                    icon: $0.icon,
                    color: $0.color,
                    urlAbsoluteString: $0.url?.absoluteString,
                    priority: $0.priority,
                    format: ControlSidebarMetadataFormat(rawValue: $0.format.rawValue) ?? .plain
                )
            },
            metadataBlocks: tab.sidebarMetadataBlocksInDisplayOrder().map {
                ControlSidebarMetadataBlockSnapshot(
                    key: $0.key,
                    markdown: $0.markdown,
                    priority: $0.priority
                )
            },
            logCount: tab.logEntries.count,
            recentLogEntries: tab.logEntries.suffix(5).map {
                ControlSidebarLogEntrySnapshot(
                    levelRawValue: $0.level.rawValue,
                    message: $0.message,
                    source: $0.source
                )
            }
        )
    }

    func controlSidebarReset(tabArg: String?) -> Bool {
        guard let tab = controlSidebarResolveTabForReport(tabArg: tabArg) else {
            return false
        }
        tab.resetSidebarContext(reason: "reset_sidebar")
        return true
    }

    func controlSidebarApplyRightSidebarRemoteCommand(tokens: [String]) -> ControlSidebarRightSidebarResolution {
        let parsed = RightSidebarRemoteRequest.parse(tokens: tokens)
        let request: RightSidebarRemoteRequest
        switch parsed {
        case .success(let value):
            request = value
        case .failure(let error):
            return .failure(message: error.message)
        }

        guard let app = AppDelegate.shared else {
            return .failure(message: String(localized: "rightSidebar.remote.error.appDelegateUnavailable", defaultValue: "ERROR: App delegate not available"))
        }
        switch app.applyRightSidebarRemoteCommand(request.command, target: request.target) {
        case .ok:
            return .ok
        case .state(let state):
            return .state(visible: state.visible, modeRawValue: state.modeRawValue)
        case .failure(let message):
            return .failure(message: message)
        }
    }
}
