import CmuxRemoteSession
import Bonsplit
import CmuxControlSocket
import Foundation
import CmuxWorkspaces

/// The surface-domain reporting (`report_tty` / `report_pwd` /
/// `report_shell_state` / `ports_kick`) witnesses, plus the token parsers.
/// Split out of `TerminalController+ControlSurfaceContext` to keep the
/// conformance readable; see that file's doc comment for the overview.
extension TerminalController {

    // MARK: - token parsers

    nonisolated func controlSurfaceParseShellActivityState(_ rawState: String) -> String? {
        Self.parseReportedShellActivityState(rawState)?.rawValue
    }

    nonisolated func controlSurfaceParsePortScanKickReason(_ rawReason: String) -> String? {
        Self.parseRemotePortScanKickReason(rawReason)?.rawValue
    }

    // MARK: - report_tty

    func controlSurfaceReportTTY(
        workspaceID: UUID,
        requestedSurfaceID: UUID?,
        ttyName: String
    ) -> ControlSurfaceReportTTYResolution {
        guard let tab = controlTabForSidebarMutation(id: workspaceID) else {
            return .workspaceNotFound
        }
        let validSurfaceIds = Set(tab.panels.keys)
        tab.pruneSurfaceMetadata(validSurfaceIds: validSurfaceIds)

        let surfaceId = controlResolveReportedSurfaceId(
            in: tab,
            requestedSurfaceId: requestedSurfaceID,
            validSurfaceIds: validSurfaceIds
        )
        guard let surfaceId, validSurfaceIds.contains(surfaceId) else {
            if tab.isRemoteWorkspace, validSurfaceIds.isEmpty {
                tab.rememberPendingRemoteSurfaceTTY(ttyName, requestedSurfaceId: requestedSurfaceID)
                return .pending
            }
            return .surfaceNotFound
        }

        tab.surfaceTTYNames[surfaceId] = ttyName
        if tab.isRemoteWorkspace {
            tab.syncRemotePortScanTTYs()
            _ = tab.applyPendingRemoteSurfacePortKickIfNeeded(to: surfaceId)
        } else {
            PortScanner.shared.registerTTY(workspaceId: workspaceID, panelId: surfaceId, ttyName: ttyName)
        }
        return .recorded(surfaceID: surfaceId)
    }

    // MARK: - report_pwd

    func controlSurfaceReportPWD(
        workspaceID: UUID,
        requestedSurfaceID: UUID?,
        path: String
    ) -> ControlSurfaceReportPWDResolution {
        guard let tab = controlTabForSidebarMutation(id: workspaceID) else {
            return .workspaceNotFound
        }
        let validSurfaceIds = Set(tab.panels.keys)
        tab.pruneSurfaceMetadata(validSurfaceIds: validSurfaceIds)

        let surfaceId = controlResolveReportedSurfaceId(
            in: tab,
            requestedSurfaceId: requestedSurfaceID,
            validSurfaceIds: validSurfaceIds
        )
        guard let surfaceId, validSurfaceIds.contains(surfaceId) else {
            if tab.isRemoteWorkspace, validSurfaceIds.isEmpty {
                tab.rememberPendingRemoteSurfacePWD(path, requestedSurfaceId: requestedSurfaceID)
                return .pending
            }
            return .surfaceNotFound
        }

        if let tabManager = AppDelegate.shared?.tabManagerFor(tabId: workspaceID) ?? tabManager {
            tabManager.updateReportedSurfaceDirectory(tabId: workspaceID, surfaceId: surfaceId, directory: path)
        } else if tab.isRemoteTerminalSurface(surfaceId) {
            _ = tab.updateRemotePanelDirectoryWithMetadata(panelId: surfaceId, directory: path)
        } else {
            _ = tab.updatePanelDirectory(panelId: surfaceId, directory: path)
        }
        return .recorded(surfaceID: surfaceId)
    }

    // MARK: - report_shell_state

    func controlSurfaceReportShellState(
        workspaceID: UUID,
        requestedSurfaceID: UUID?,
        stateRawValue: String
    ) -> ControlSurfaceReportShellStateResolution {
        guard let state = PanelShellActivityState(rawValue: stateRawValue) else {
            // Unreachable: the coordinator only forwards a value the app produced.
            return .pending
        }
        if let requestedSurfaceID {
            let shouldPublish = socketFastPathState.shouldPublishShellActivity(
                workspaceId: workspaceID,
                panelId: requestedSurfaceID,
                state: state.rawValue
            )
            if shouldPublish {
                DispatchQueue.main.async {
                    if let dock = DockSplitStore.liveStores.first(where: {
                        $0.containsPanel(requestedSurfaceID)
                    }) {
                        dock.updatePanelShellActivityState(panelId: requestedSurfaceID, state: state)
                        return
                    }
                    guard let tabManager = AppDelegate.shared?.tabManagerFor(tabId: workspaceID) else { return }
                    tabManager.updateSurfaceShellActivity(
                        tabId: workspaceID,
                        surfaceId: requestedSurfaceID,
                        state: state
                    )
                }
            }
            return .explicit(surfaceID: requestedSurfaceID, published: shouldPublish)
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard let tab = self.controlTabForSidebarMutation(id: workspaceID) else { return }
            let validSurfaceIds = Set(tab.panels.keys)
            tab.pruneSurfaceMetadata(validSurfaceIds: validSurfaceIds)
            let surfaceId = self.controlResolveReportedSurfaceId(
                in: tab,
                requestedSurfaceId: requestedSurfaceID,
                validSurfaceIds: validSurfaceIds
            )
            guard let surfaceId, validSurfaceIds.contains(surfaceId) else { return }
            guard let tabManager = AppDelegate.shared?.tabManagerFor(tabId: tab.id) else { return }
            tabManager.updateSurfaceShellActivity(tabId: tab.id, surfaceId: surfaceId, state: state)
        }
        return .pending
    }

    // MARK: - ports_kick

    func controlSurfacePortsKick(
        workspaceID: UUID,
        requestedSurfaceID: UUID?,
        reasonRawValue: String
    ) -> ControlSurfacePortsKickResolution {
        guard let reason = PortScanKickReason(rawValue: reasonRawValue) else {
            // Unreachable: the coordinator only forwards a value the app produced.
            return .workspaceNotFound
        }
        guard let tab = controlTabForSidebarMutation(id: workspaceID) else {
            return .workspaceNotFound
        }
        let validSurfaceIds = Set(tab.panels.keys)
        tab.pruneSurfaceMetadata(validSurfaceIds: validSurfaceIds)

        let surfaceId = controlResolveReportedSurfaceId(
            in: tab,
            requestedSurfaceId: requestedSurfaceID,
            validSurfaceIds: validSurfaceIds
        )
        guard let surfaceId, validSurfaceIds.contains(surfaceId) else {
            if tab.isRemoteWorkspace, validSurfaceIds.isEmpty {
                tab.rememberPendingRemoteSurfacePortKick(reason: reason, requestedSurfaceId: requestedSurfaceID)
                return .pending
            }
            return .surfaceNotFound
        }

        if tab.isRemoteWorkspace {
            tab.kickRemotePortScan(panelId: surfaceId, reason: reason)
        } else {
            PortScanner.shared.kick(workspaceId: workspaceID, panelId: surfaceId)
        }
        return .kicked(surfaceID: surfaceId)
    }

    // MARK: - shared report helpers (twins of file-private members)

    /// The byte-faithful twin of the file-private `tabForSidebarMutation(id:)`:
    /// the controller's own TabManager first, then any window's TabManager.
    func controlTabForSidebarMutation(id: UUID) -> Workspace? {
        if let tab = tabManager?.tabs.first(where: { $0.id == id }) {
            return tab
        }
        if let otherManager = AppDelegate.shared?.tabManagerFor(tabId: id) {
            return otherManager.tabs.first(where: { $0.id == id })
        }
        return nil
    }

    /// The byte-faithful twin of the file-private `resolveReportedSurfaceId`.
    func controlResolveReportedSurfaceId(
        in workspace: Workspace,
        requestedSurfaceId: UUID?,
        validSurfaceIds: Set<UUID>
    ) -> UUID? {
        if let requestedSurfaceId {
            guard validSurfaceIds.contains(requestedSurfaceId) else { return nil }
            return requestedSurfaceId
        }
        if let focusedSurfaceId = workspace.focusedPanelId,
           validSurfaceIds.contains(focusedSurfaceId),
           (!workspace.isRemoteWorkspace || workspace.isRemoteTerminalSurface(focusedSurfaceId)) {
            return focusedSurfaceId
        }
        guard workspace.isRemoteWorkspace else { return nil }
        let remoteTerminalSurfaceIds = validSurfaceIds.filter { workspace.isRemoteTerminalSurface($0) }
        if remoteTerminalSurfaceIds.count == 1 {
            return remoteTerminalSurfaceIds.first
        }
        if validSurfaceIds.count == 1 {
            return validSurfaceIds.first
        }
        return nil
    }
}
