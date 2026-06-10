import AppKit
import CmuxAuthRuntime
import CmuxControlSocket
import CmuxSettings
import CmuxSocketControl
import CmuxSwiftRenderUI
import Carbon.HIToolbox
import CMUXMobileCore
import CMUXWorkstream
import Foundation
import Bonsplit
import WebKit


// MARK: - V2 surface TTY/shell-state/ports reporting
extension TerminalController {
    func v2SurfaceReportTTY(params: [String: Any]) -> V2CallResult {
        guard let workspaceId = v2UUID(params, "workspace_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid workspace_id", data: nil)
        }
        let requestedSurfaceId = v2UUID(params, "surface_id")
        if v2HasNonNullParam(params, "surface_id"), requestedSurfaceId == nil {
            return .err(code: "invalid_params", message: "Missing or invalid surface_id", data: nil)
        }
        guard let ttyName = v2RawString(params, "tty_name")?.trimmingCharacters(in: .whitespacesAndNewlines),
              !ttyName.isEmpty else {
            return .err(code: "invalid_params", message: "Missing tty_name", data: nil)
        }

        var result: V2CallResult = .err(
            code: "not_found",
            message: "Workspace not found",
            data: [
                "workspace_id": workspaceId.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: workspaceId),
                "surface_id": v2OrNull(requestedSurfaceId?.uuidString),
                "surface_ref": v2Ref(kind: .surface, uuid: requestedSurfaceId),
            ]
        )

        v2MainSync {
            guard let tab = self.tabForSidebarMutation(id: workspaceId) else {
                return
            }
            let validSurfaceIds = Set(tab.panels.keys)
            tab.pruneSurfaceMetadata(validSurfaceIds: validSurfaceIds)

            let surfaceId = self.resolveReportedSurfaceId(
                in: tab,
                requestedSurfaceId: requestedSurfaceId,
                validSurfaceIds: validSurfaceIds
            )
            guard let surfaceId, validSurfaceIds.contains(surfaceId) else {
                if tab.isRemoteWorkspace, validSurfaceIds.isEmpty {
                    tab.rememberPendingRemoteSurfaceTTY(ttyName, requestedSurfaceId: requestedSurfaceId)
                    result = .ok([
                        "workspace_id": workspaceId.uuidString,
                        "workspace_ref": v2Ref(kind: .workspace, uuid: workspaceId),
                        "surface_id": v2OrNull(requestedSurfaceId?.uuidString),
                        "surface_ref": v2Ref(kind: .surface, uuid: requestedSurfaceId),
                        "tty_name": ttyName,
                        "pending": true,
                    ])
                    return
                }
                result = .err(
                    code: "not_found",
                    message: "Surface not found",
                    data: [
                        "workspace_id": workspaceId.uuidString,
                        "workspace_ref": v2Ref(kind: .workspace, uuid: workspaceId),
                        "surface_id": v2OrNull(requestedSurfaceId?.uuidString),
                        "surface_ref": v2Ref(kind: .surface, uuid: requestedSurfaceId),
                    ]
                )
                return
            }

            tab.surfaceTTYNames[surfaceId] = ttyName
            if tab.isRemoteWorkspace {
                tab.syncRemotePortScanTTYs()
                _ = tab.applyPendingRemoteSurfacePortKickIfNeeded(to: surfaceId)
            } else {
                PortScanner.shared.registerTTY(workspaceId: workspaceId, panelId: surfaceId, ttyName: ttyName)
            }

            result = .ok([
                "workspace_id": workspaceId.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: workspaceId),
                "surface_id": surfaceId.uuidString,
                "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                "tty_name": ttyName,
            ])
        }

        return result
    }

    func v2SurfaceReportShellState(params: [String: Any]) -> V2CallResult {
        guard let workspaceId = v2UUID(params, "workspace_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid workspace_id", data: nil)
        }
        let requestedSurfaceId = v2UUID(params, "surface_id")
        if v2HasNonNullParam(params, "surface_id"), requestedSurfaceId == nil {
            return .err(code: "invalid_params", message: "Missing or invalid surface_id", data: nil)
        }
        let rawState = v2RawString(params, "state")
            ?? v2RawString(params, "shell_state")
            ?? v2RawString(params, "activity")
        guard let rawState,
              let state = Self.parseReportedShellActivityState(rawState) else {
            return .err(code: "invalid_params", message: "state must be prompt, running, or unknown", data: nil)
        }

        if let requestedSurfaceId {
            let shouldPublish = socketFastPathState.shouldPublishShellActivity(
                workspaceId: workspaceId,
                panelId: requestedSurfaceId,
                state: state.rawValue
            )
            if shouldPublish {
                DispatchQueue.main.async {
                    guard let tabManager = AppDelegate.shared?.tabManagerFor(tabId: workspaceId) else { return }
                    tabManager.updateSurfaceShellActivity(
                        tabId: workspaceId,
                        surfaceId: requestedSurfaceId,
                        state: state
                    )
                }
            }
            return .ok([
                "workspace_id": workspaceId.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: workspaceId),
                "surface_id": requestedSurfaceId.uuidString,
                "surface_ref": v2Ref(kind: .surface, uuid: requestedSurfaceId),
                "state": state.rawValue,
                "published": shouldPublish,
            ])
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard let tab = self.tabForSidebarMutation(id: workspaceId) else {
                return
            }
            let validSurfaceIds = Set(tab.panels.keys)
            tab.pruneSurfaceMetadata(validSurfaceIds: validSurfaceIds)

            let surfaceId = self.resolveReportedSurfaceId(
                in: tab,
                requestedSurfaceId: requestedSurfaceId,
                validSurfaceIds: validSurfaceIds
            )
            guard let surfaceId, validSurfaceIds.contains(surfaceId) else {
                return
            }

            guard let tabManager = AppDelegate.shared?.tabManagerFor(tabId: tab.id) else {
                return
            }
            tabManager.updateSurfaceShellActivity(tabId: tab.id, surfaceId: surfaceId, state: state)
        }

        return .ok([
            "workspace_id": workspaceId.uuidString,
            "workspace_ref": v2Ref(kind: .workspace, uuid: workspaceId),
            "surface_id": NSNull(),
            "surface_ref": NSNull(),
            "state": state.rawValue,
            "published": true,
            "pending": true,
        ])
    }

    func v2SurfacePortsKick(params: [String: Any]) -> V2CallResult {
        guard let workspaceId = v2UUID(params, "workspace_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid workspace_id", data: nil)
        }
        let requestedSurfaceId = v2UUID(params, "surface_id")
        if v2HasNonNullParam(params, "surface_id"), requestedSurfaceId == nil {
            return .err(code: "invalid_params", message: "Missing or invalid surface_id", data: nil)
        }
        let reason: WorkspaceRemoteSessionController.PortScanKickReason
        if let rawReason = v2RawString(params, "reason") {
            guard let parsedReason = Self.parseRemotePortScanKickReason(rawReason) else {
                return .err(
                    code: "invalid_params",
                    message: "reason must be command or refresh",
                    data: nil
                )
            }
            reason = parsedReason
        } else {
            reason = .command
        }

        var result: V2CallResult = .err(
            code: "not_found",
            message: "Workspace not found",
            data: [
                "workspace_id": workspaceId.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: workspaceId),
                "surface_id": v2OrNull(requestedSurfaceId?.uuidString),
                "surface_ref": v2Ref(kind: .surface, uuid: requestedSurfaceId),
            ]
        )

        v2MainSync {
            guard let tab = self.tabForSidebarMutation(id: workspaceId) else {
                return
            }
            let validSurfaceIds = Set(tab.panels.keys)
            tab.pruneSurfaceMetadata(validSurfaceIds: validSurfaceIds)

            let surfaceId = self.resolveReportedSurfaceId(
                in: tab,
                requestedSurfaceId: requestedSurfaceId,
                validSurfaceIds: validSurfaceIds
            )
            guard let surfaceId, validSurfaceIds.contains(surfaceId) else {
                if tab.isRemoteWorkspace, validSurfaceIds.isEmpty {
                    tab.rememberPendingRemoteSurfacePortKick(
                        reason: reason,
                        requestedSurfaceId: requestedSurfaceId
                    )
                    result = .ok([
                        "workspace_id": workspaceId.uuidString,
                        "workspace_ref": v2Ref(kind: .workspace, uuid: workspaceId),
                        "surface_id": v2OrNull(requestedSurfaceId?.uuidString),
                        "surface_ref": v2Ref(kind: .surface, uuid: requestedSurfaceId),
                        "reason": reason.rawValue,
                        "pending": true,
                    ])
                    return
                }
                result = .err(
                    code: "not_found",
                    message: "Surface not found",
                    data: [
                        "workspace_id": workspaceId.uuidString,
                        "workspace_ref": v2Ref(kind: .workspace, uuid: workspaceId),
                        "surface_id": v2OrNull(requestedSurfaceId?.uuidString),
                        "surface_ref": v2Ref(kind: .surface, uuid: requestedSurfaceId),
                    ]
                )
                return
            }

            if tab.isRemoteWorkspace {
                tab.kickRemotePortScan(panelId: surfaceId, reason: reason)
            } else {
                PortScanner.shared.kick(workspaceId: workspaceId, panelId: surfaceId)
            }

            result = .ok([
                "workspace_id": workspaceId.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: workspaceId),
                "surface_id": surfaceId.uuidString,
                "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                "reason": reason.rawValue,
            ])
        }

        return result
    }

    @MainActor
    private func resolveReportedSurfaceId(
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
