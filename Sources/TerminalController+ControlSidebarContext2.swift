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

    func controlSidebarScheduleScopedGitBranchUpdate(
        scope: ControlSidebarPanelScope,
        branch: String,
        isDirty: Bool?
    ) {
        TerminalMutationBus.shared.enqueueMainActorMutation {
            guard let tabManager = AppDelegate.shared?.tabManagerFor(tabId: scope.workspaceID),
                  let tab = tabManager.tabs.first(where: { $0.id == scope.workspaceID }) else {
                return
            }
            let validSurfaceIds = Set(tab.panels.keys)
            tab.pruneSurfaceMetadata(validSurfaceIds: validSurfaceIds)
            guard validSurfaceIds.contains(scope.panelID) else { return }
            guard SidebarWorkspaceDetailDefaults.watchGitStatusValue(defaults: .standard) else {
                tabManager.clearSurfaceGitBranch(tabId: scope.workspaceID, surfaceId: scope.panelID)
                return
            }
            tabManager.updateSurfaceGitBranch(
                tabId: scope.workspaceID,
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

    func controlSidebarScheduleScopedGitBranchClear(scope: ControlSidebarPanelScope) {
        TerminalMutationBus.shared.enqueueMainActorMutation {
            guard let tabManager = AppDelegate.shared?.tabManagerFor(tabId: scope.workspaceID),
                  let tab = tabManager.tabs.first(where: { $0.id == scope.workspaceID }) else {
                return
            }
            let validSurfaceIds = Set(tab.panels.keys)
            tab.pruneSurfaceMetadata(validSurfaceIds: validSurfaceIds)
            guard validSurfaceIds.contains(scope.panelID) else { return }
            tabManager.clearSurfaceGitBranch(tabId: scope.workspaceID, surfaceId: scope.panelID)
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

    func controlSidebarIsValidPullRequestState(_ raw: String) -> Bool {
        SidebarPullRequestStatus(rawValue: raw) != nil
    }

    func controlSidebarSchedulePanelPullRequestUpdate(
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

    func controlSidebarSchedulePanelPullRequestClear(target: ControlSidebarPanelMutationTarget) {
        controlSidebarSchedulePanelMetadataMutation(target: target) { tab, surfaceId in
            tab.clearPanelPullRequest(panelId: surfaceId)
        }
    }

    func controlSidebarSchedulePanelPullRequestAction(
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
        guard let tab = controlSidebarResolveTabForReport(tabArg: tabArg) else {
            return .tabNotFound
        }

        let validSurfaceIds = Set(tab.panels.keys)
        tab.pruneSurfaceMetadata(validSurfaceIds: validSurfaceIds)

        if let panelArg {
            if panelArg.isEmpty {
                return .missingPanelArg
            }
            guard let surfaceId = UUID(uuidString: panelArg) else {
                return .invalidPanelArg(panelArg)
            }
            guard validSurfaceIds.contains(surfaceId) else {
                return .panelNotFound(surfaceId)
            }
            tab.surfaceListeningPorts.removeValue(forKey: surfaceId)
        } else {
            tab.surfaceListeningPorts.removeAll()
        }
        tab.recomputeListeningPorts()
        return .done
    }

    func controlSidebarScheduleScopedDirectoryUpdate(scope: ControlSidebarPanelScope, directory: String) {
        TerminalMutationBus.shared.enqueueMainActorMutation {
            guard let tabManager = AppDelegate.shared?.tabManagerFor(tabId: scope.workspaceID),
                  let tab = tabManager.tabs.first(where: { $0.id == scope.workspaceID }) else {
                return
            }
            let validSurfaceIds = Set(tab.panels.keys)
            tab.pruneSurfaceMetadata(validSurfaceIds: validSurfaceIds)
            guard validSurfaceIds.contains(scope.panelID) else { return }
            tabManager.updateSurfaceDirectory(tabId: scope.workspaceID, surfaceId: scope.panelID, directory: directory)
        }
    }

    func controlSidebarUpdateDirectory(tabArg: String?, panelArg: String?, directory: String) -> ControlSidebarPanelWriteResolution {
        guard let tabManager else { return .tabNotFound }
        return controlSidebarResolvePanelWrite(
            tabArg: tabArg,
            panelArg: panelArg,
            prune: true,
            requireLiveSurface: true
        ) { tab, surfaceId in
            tabManager.updateSurfaceDirectory(tabId: tab.id, surfaceId: surfaceId, directory: directory)
        }
    }

    func controlSidebarScheduleScopedShellState(scope: ControlSidebarPanelScope, stateRawValue: String) {
        guard let state = PanelShellActivityState(rawValue: stateRawValue) else {
            // Unreachable: the coordinator only forwards a value this app produced.
            return
        }
        guard socketFastPathState.shouldPublishShellActivity(
            workspaceId: scope.workspaceID,
            panelId: scope.panelID,
            state: state.rawValue
        ) else {
            return
        }
        TerminalMutationBus.shared.enqueueMainActorMutation {
            guard let tabManager = AppDelegate.shared?.tabManagerFor(tabId: scope.workspaceID) else { return }
            tabManager.updateSurfaceShellActivity(tabId: scope.workspaceID, surfaceId: scope.panelID, state: state)
        }
    }

    func controlSidebarUpdateShellState(tabArg: String?, panelArg: String?, stateRawValue: String) -> ControlSidebarPanelWriteResolution {
        guard let state = PanelShellActivityState(rawValue: stateRawValue) else {
            // Unreachable: the coordinator only forwards a value this app produced.
            return .tabNotFound
        }
        guard let tabManager else { return .tabNotFound }
        return controlSidebarResolvePanelWrite(
            tabArg: tabArg,
            panelArg: panelArg,
            prune: true,
            requireLiveSurface: true
        ) { tab, surfaceId in
            tabManager.updateSurfaceShellActivity(tabId: tab.id, surfaceId: surfaceId, state: state)
        }
    }

    func controlSidebarScheduleScopedTTY(scope: ControlSidebarPanelScope, ttyName: String) {
        TerminalMutationBus.shared.enqueueMainActorMutation {
            guard let tabManager = AppDelegate.shared?.tabManagerFor(tabId: scope.workspaceID),
                  let tab = tabManager.tabs.first(where: { $0.id == scope.workspaceID }) else {
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
                PortScanner.shared.registerTTY(workspaceId: scope.workspaceID, panelId: scope.panelID, ttyName: ttyName)
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

    func controlSidebarScheduleScopedPortsKick(scope: ControlSidebarPanelScope, reasonRawValue: String) {
        guard let reason = PortScanKickReason(rawValue: reasonRawValue) else {
            // Unreachable: the coordinator only forwards a value this app produced.
            return
        }
        TerminalMutationBus.shared.enqueueMainActorMutation {
            guard let tabManager = AppDelegate.shared?.tabManagerFor(tabId: scope.workspaceID),
                  let tab = tabManager.tabs.first(where: { $0.id == scope.workspaceID }) else {
                return
            }
            let validSurfaceIds = Set(tab.panels.keys)
            tab.pruneSurfaceMetadata(validSurfaceIds: validSurfaceIds)
            guard validSurfaceIds.contains(scope.panelID) else { return }
            if tab.isRemoteWorkspace {
                tab.kickRemotePortScan(panelId: scope.panelID, reason: reason)
            } else {
                PortScanner.shared.kick(workspaceId: scope.workspaceID, panelId: scope.panelID)
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
           let focusedDir = tab.panelDirectories[focused] {
            focusedPanel = ControlSidebarFocusedPanelInfo(panelID: focused, directory: focusedDir)
        } else {
            focusedPanel = nil
        }

        let gitBranch = tab.gitBranch.map {
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
            currentDirectory: tab.currentDirectory,
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
