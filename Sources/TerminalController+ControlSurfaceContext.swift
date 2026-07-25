import AppKit
import Bonsplit
import CmuxControlSocket
import Foundation
import GhosttyKit

extension TerminalController {
    /// Socket error text extracted because `TerminalController.swift` sits at
    /// its file-length budget.
    nonisolated static var terminalSurfaceUnavailableSocketError: String {
        "ERROR: \(terminalSurfaceUnavailableMessage)"
    }
}

extension TerminalController {
    @MainActor
    func v2AgentSessionSubmit(params: [String: Any]) async -> V2CallResult {
        guard let text = v2String(params, "text")
            ?? v2String(params, "message")
            ?? v2String(params, "prompt")
            ?? v2String(params, "body") else {
            return .err(code: "invalid_params", message: "Missing text", data: nil)
        }
        let providerID: AgentSessionProviderID?
        if let rawProvider = v2String(params, "provider_id") ?? v2String(params, "provider") {
            guard let parsedProvider = AgentSessionProviderID(rawValue: rawProvider) else {
                return .err(
                    code: "invalid_params",
                    message: "Invalid provider",
                    data: ["provider": rawProvider]
                )
            }
            providerID = parsedProvider
        } else {
            providerID = nil
        }
        let permissionMode: AgentSessionPermissionMode
        if let rawPermissionMode = v2String(params, "permission_mode") ?? v2String(params, "permissionMode") {
            guard let parsedPermissionMode = AgentSessionPermissionMode(rawValue: rawPermissionMode) else {
                return .err(
                    code: "invalid_params",
                    message: "Invalid permission mode",
                    data: ["permission_mode": rawPermissionMode]
                )
            }
            permissionMode = parsedPermissionMode
        } else {
            permissionMode = .standard
        }

        v2RefreshKnownRefs()
        let routing = ControlRoutingSelectors(
            hasWindowIDParam: v2HasNonNullParam(params, "window_id"),
            windowID: v2UUID(params, "window_id"),
            groupID: v2UUID(params, "group_id"),
            workspaceID: v2UUID(params, "workspace_id"),
            surfaceID: v2UUID(params, "surface_id")
                ?? v2UUID(params, "terminal_id")
                ?? v2UUID(params, "tab_id"),
            paneID: v2UUID(params, "pane_id")
        )
        guard let target = agentSessionSubmitTarget(routing: routing) else {
            return .err(code: "not_found", message: "Agent Session surface not found", data: nil)
        }
        guard let agentPanel = target.panel as? AgentSessionPanel else {
            return .err(
                code: "invalid_params",
                message: "Surface is not an Agent Session",
                data: ["surface_id": target.panel.id.uuidString]
            )
        }

        do {
            let result = try await agentPanel.submitFromControl(
                providerID: providerID,
                permissionMode: permissionMode,
                text: text
            )
            let session = result.session
            return .ok([
                "workspace_id": target.workspaceID.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: target.workspaceID),
                "window_id": v2OrNull(target.windowID?.uuidString),
                "window_ref": v2Ref(kind: .window, uuid: target.windowID),
                "surface_id": target.panel.id.uuidString,
                "surface_ref": v2Ref(kind: .surface, uuid: target.panel.id),
                "session_id": session.sessionId,
                "provider_id": session.providerID.rawValue,
                "started_provider": result.startedProvider,
                "executable_path": session.executablePath,
                "arguments": session.arguments,
                "working_directory": v2OrNull(session.workingDirectory),
            ])
        } catch let error as AgentExecutableResolverError {
            return .err(
                code: "provider_unavailable",
                message: error.message,
                data: nil
            )
        } catch let error as AgentSessionBridgeError {
            return .err(
                code: error.code,
                message: error.localizedDescription,
                data: nil
            )
        } catch {
            return .err(
                code: "agent_session_error",
                message: String(describing: error),
                data: nil
            )
        }
    }

    private struct AgentSessionSubmitTarget {
        let workspaceID: UUID
        let windowID: UUID?
        let panel: any Panel
    }

    @MainActor
    private func agentSessionSubmitTarget(routing: ControlRoutingSelectors) -> AgentSessionSubmitTarget? {
        guard let tabManager = resolveTabManager(routing: routing) else {
            return nil
        }
        if let dock = windowDockForRouting(routing, tabManager: tabManager) {
            let panels = orderedPanels(in: dock)
            let panel = agentSessionPanelCandidate(
                panels: panels,
                explicitSurfaceID: routing.surfaceID,
                focusedPanelID: dock.focusedPanelId
            )
            return panel.map {
                AgentSessionSubmitTarget(
                    workspaceID: dock.workspaceId,
                    windowID: dockResultWindowId(for: dock, tabManager: tabManager),
                    panel: $0
                )
            }
        }

        guard let workspace = resolveSurfaceWorkspace(routing: routing, tabManager: tabManager) else {
            return nil
        }
        let panels = controlSurfacePanels(workspace: workspace)
        let panel = agentSessionPanelCandidate(
            panels: panels,
            explicitSurfaceID: routing.surfaceID,
            focusedPanelID: workspace.focusedPanelId
        )
        return panel.map {
            AgentSessionSubmitTarget(
                workspaceID: workspace.id,
                windowID: v2ResolveWindowId(tabManager: tabManager),
                panel: $0
            )
        }
    }

    private func agentSessionPanelCandidate(
        panels: [any Panel],
        explicitSurfaceID: UUID?,
        focusedPanelID: UUID?
    ) -> (any Panel)? {
        if let explicitSurfaceID {
            return panels.first { $0.id == explicitSurfaceID }
        }
        if let focusedPanelID,
           let focused = panels.first(where: { $0.id == focusedPanelID }) {
            return focused
        }
        return panels.first { $0 is AgentSessionPanel }
    }
}

/// The surface-domain witnesses are the byte-faithful bodies of the former
/// `v2Surface*` / `v2DebugTerminals` dispatchers, minus the per-read `v2MainSync`
/// hop: the coordinator already runs on the main actor inside the socket-command
/// policy scope, so each hop would re-apply the identical thread-local
/// focus-allowance stack — a no-op.
///
/// App-coupled resolution (`resolveTabManager(routing:)`, `v2ResolveWindowId`, the
/// Bonsplit layout, surface creation/move, the Ghostty reads, the resume approval
/// flow, the `debug.terminals` table) stays here; the seam exposes only Sendable
/// snapshots, resolution enums, and one bridged ``JSONValue`` (`debug.terminals`).
/// Every blocking `NSAlert` and `String(localized:)` resolves here, in the app
/// bundle, so translations survive.
extension TerminalController: ControlSurfaceContext {
    func controlSurfaceRoutingResolvesTabManager(routing: ControlRoutingSelectors) -> Bool {
        resolveTabManager(routing: routing) != nil
    }

    /// The routing twin of the legacy `v2ResolveWorkspace(params:tabManager:)`.
    /// `internal` (not `private`) so the surface witnesses in the sibling
    /// `+ControlSurfaceContext2`/`3` files share it.
    func resolveSurfaceWorkspace(
        routing: ControlRoutingSelectors,
        tabManager: TabManager
    ) -> Workspace? {
        if let wsId = routing.workspaceID {
            guard !AppDelegate.isWindowDockRoutingId(wsId) else { return nil }
            return tabManager.tabs.first(where: { $0.id == wsId })
        }
        if let surfaceId = routing.surfaceID {
            if let workspace = tabManager.tabs.first(where: { $0.panels[surfaceId] != nil }) {
                return workspace
            }
            if let workspace = tabManager.tabs.first(where: {
                $0.remoteTmuxControlPane(surfaceID: surfaceId) != nil
            }) {
                return workspace
            }
            guard windowDockContainingPanel(surfaceId) == nil else { return nil }
            return tabManager.tabs.first(where: { $0.containsDockPanel(surfaceId) })
        }
        if let paneId = routing.paneID {
            if let located = v2LocatePane(paneId) {
                guard located.tabManager === tabManager else { return nil }
                return located.workspace
            }
            if let workspace = tabManager.tabs.first(where: {
                $0.remoteTmuxControlPane(paneID: paneId) != nil
            }) {
                return workspace
            }
            guard windowDockContainingPane(paneId) == nil else { return nil }
            if let located = locateDockPane(paneId), located.tabManager === tabManager {
                return located.workspace
            }
        }
        guard let wsId = tabManager.selectedTabId else { return nil }
        return tabManager.tabs.first(where: { $0.id == wsId })
    }

    /// Converts an app resume-binding snapshot (after `applyingStoredApproval`) into
    /// the seam value type, byte-faithful to `v2SurfaceResumeBindingPayload`.
    /// `internal` (not `private`) so the resume witnesses in the sibling
    /// `+ControlSurfaceContext3` file share it.
    func controlResumeBinding(
        from binding: SurfaceResumeBindingSnapshot?
    ) -> ControlSurfaceResumeBinding? {
        guard let binding else { return nil }
        let effective = SurfaceResumeApprovalStore.applyingStoredApproval(to: binding)
        let remoteContext = effective.launchFlavor.remoteContext
        return ControlSurfaceResumeBinding(
            name: effective.name,
            kind: effective.kind,
            command: effective.command,
            cwd: effective.cwd,
            checkpointID: effective.checkpointId,
            source: effective.source,
            environment: effective.environment,
            autoResume: effective.allowsAutomaticResume,
            approvalPolicyRawValue: effective.approvalPolicy?.rawValue,
            approvalRecordID: effective.approvalRecordId,
            executionLocationRawValue: effective.launchFlavor.executionLocationRawValue,
            remoteWorkspaceID: remoteContext?.workspaceID,
            remoteSurfaceID: remoteContext?.surfaceID,
            remotePTYSessionID: remoteContext?.persistentPTYSessionID,
            updatedAt: effective.updatedAt
        )
    }

    // MARK: - list

    func controlSurfaceList(routing: ControlRoutingSelectors) -> ControlSurfaceListSnapshot? {
        guard let tabManager = resolveTabManager(routing: routing) else {
            return nil
        }
        if let dock = windowDockForRouting(routing, tabManager: tabManager) {
            return controlDockSurfaceList(dock: dock, tabManager: tabManager)
        }
        guard let ws = resolveSurfaceWorkspace(routing: routing, tabManager: tabManager) else { return nil }

        return ControlSurfaceListSnapshot(
            workspaceID: ws.id,
            windowID: v2ResolveWindowId(tabManager: tabManager),
            surfaces: controlSurfaceSummaries(workspace: ws) +
                controlTopologyDocks(workspace: ws, tabManager: tabManager)
                .flatMap { controlDockSurfaceSummaries(dock: $0) }
        )
    }

    // MARK: - current

    func controlSurfaceCurrent(routing: ControlRoutingSelectors) -> ControlSurfaceCurrentSnapshot? {
        guard let tabManager = resolveTabManager(routing: routing) else {
            return nil
        }
        if let dock = windowDockForRouting(routing, tabManager: tabManager) {
            let surfaceId = dock.focusedPanelId ?? orderedPanels(in: dock).first?.id
            let paneId = surfaceId.flatMap { dock.paneId(forPanelId: $0)?.id }
            return ControlSurfaceCurrentSnapshot(
                windowID: dockResultWindowId(for: dock, tabManager: tabManager),
                workspaceID: dock.workspaceId,
                paneID: paneId,
                surfaceID: surfaceId,
                surfaceTypeRawValue: surfaceId.flatMap { dock.panels[$0]?.panelType.rawValue }
            )
        }
        guard let ws = resolveSurfaceWorkspace(routing: routing, tabManager: tabManager) else { return nil }
        let containerPanelID = ws.focusedPanelId ?? orderedPanels(in: ws).first?.id
        let projection = containerPanelID.flatMap {
            ws.controlSurfaceProjection(forContainerPanelID: $0)
        }
        return ControlSurfaceCurrentSnapshot(
            windowID: v2ResolveWindowId(tabManager: tabManager),
            workspaceID: ws.id,
            paneID: projection?.paneID,
            surfaceID: projection?.surfaceID,
            surfaceTypeRawValue: projection?.panel.panelType.rawValue
        )
    }

    // MARK: - health

    func controlSurfaceHealth(routing: ControlRoutingSelectors) -> ControlSurfaceHealthSnapshot? {
        guard let tabManager = resolveTabManager(routing: routing) else {
            return nil
        }
        if let dock = windowDockForRouting(routing, tabManager: tabManager) {
            let items: [ControlSurfaceHealthEntry] = orderedPanels(in: dock).map { panel in
                return ControlSurfaceHealthEntry(
                    surfaceID: panel.id,
                    typeRawValue: panel.panelType.rawValue,
                    inWindow: controlSurfaceInWindow(panel)
                )
            }
            return ControlSurfaceHealthSnapshot(
                workspaceID: dock.workspaceId,
                windowID: dockResultWindowId(for: dock, tabManager: tabManager),
                surfaces: items
            )
        }
        guard let ws = resolveSurfaceWorkspace(routing: routing, tabManager: tabManager) else { return nil }
        let items: [ControlSurfaceHealthEntry] = controlSurfacePanels(workspace: ws).map { panel in
            return ControlSurfaceHealthEntry(
                surfaceID: panel.id,
                typeRawValue: panel.panelType.rawValue,
                inWindow: controlSurfaceInWindow(panel)
            )
        }
        return ControlSurfaceHealthSnapshot(
            workspaceID: ws.id,
            windowID: v2ResolveWindowId(tabManager: tabManager),
            surfaces: items
        )
    }

    private func controlSurfaceInWindow(_ panel: any Panel) -> Bool? {
        if let tp = panel as? TerminalPanel {
            return tp.surface.isViewInWindow
        }
        if let bp = panel as? BrowserPanel {
            return bp.webView.window != nil
        }
        if let ap = panel as? AgentSessionPanel {
            return ap.isWebViewInWindow
        }
        return nil
    }

    // MARK: - focus

    func controlSurfaceFocus(
        routing: ControlRoutingSelectors,
        surfaceID: UUID
    ) -> ControlSurfaceFocusResolution {
        guard let tabManager = resolveTabManager(routing: routing) else {
            return .tabManagerUnavailable
        }
        if let windowDock = windowDockContainingPanel(surfaceID) {
            // An explicit window_id or Dock-owner workspace_id naming a
            // different window's Dock fails closed.
            if windowDockMismatchesExplicitSelectors(routing, dock: windowDock, aliasTabManager: tabManager) {
                return .surfaceNotFound(surfaceID)
            }
            focusAndRevealWindowDock(for: windowDock, fallback: tabManager)
            windowDock.focusPanel(surfaceID)
            return .focused(
                windowID: windowDock.workspaceId,
                workspaceID: windowDock.workspaceId,
                surfaceID: surfaceID
            )
        }
        guard let ws = resolveSurfaceWorkspace(routing: routing, tabManager: tabManager) else {
            return .workspaceNotFound
        }
        switch ws.remoteTmuxControlSurfaceTarget(surfaceID: surfaceID) {
        case .pane(let location):
            guard focusRemoteTmuxControlPane(
                location,
                workspace: ws,
                tabManager: tabManager
            ) else {
                return .surfaceNotFound(surfaceID)
            }
            return .focused(
                windowID: v2ResolveWindowId(tabManager: tabManager),
                workspaceID: ws.id,
                surfaceID: location.pane.panel.id
            )
        case .unresolvedMirror:
            return .surfaceNotFound(surfaceID)
        case .notRemote:
            break
        }
        if let windowId = v2ResolveWindowId(tabManager: tabManager) {
            _ = AppDelegate.shared?.focusMainWindow(windowId: windowId)
            setActiveTabManager(tabManager)
        }
        if tabManager.selectedTabId != ws.id {
            tabManager.selectWorkspace(ws)
        }
        if ws.panels[surfaceID] != nil {
            ws.focusPanel(surfaceID)
        } else if ws.containsDockPanel(surfaceID) {
            revealDockForFocus(tabManager: tabManager)
            ws.dockSplit.focusPanel(surfaceID)
        } else {
            return .surfaceNotFound(surfaceID)
        }
        return .focused(
            windowID: v2ResolveWindowId(tabManager: tabManager),
            workspaceID: ws.id,
            surfaceID: surfaceID
        )
    }
}
