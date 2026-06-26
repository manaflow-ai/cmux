import CmuxControlSocket
import Foundation

@MainActor
private struct TerminalCallerNotificationTarget {
    let workspace: Workspace
    let surfaceId: UUID?
}

/// The `notification.create_for_caller` witness for the ``ControlNotificationContext``
/// seam: the byte-faithful body of the former `TerminalController.v2NotificationCreateForCaller`.
///
/// The whole multi-window target pick (the preferred ids, the caller TTY, then
/// the selected workspace, walked across every window's `TabManager`) is
/// irreducibly app-coupled, so it stays here behind the seam. The coordinator
/// parses the request (defaulting title/subtitle/body and trimming `caller_tty`)
/// and shapes the echoed identity; this witness performs the pick + delivery.
/// The legacy `runOnMain` hop is gone: the coordinator already runs on the main
/// actor, so the body is a plain in-isolation call.
@MainActor
extension TerminalController {
    func controlNotificationCreateForCaller(
        preferredWorkspaceID: UUID?,
        preferredSurfaceID: UUID?,
        callerTTY: String?,
        preferTTY: Bool,
        title: String,
        subtitle: String,
        body: String
    ) -> ControlNotificationCallerDeliveryResolution {
        guard let fallbackTabManager = activeTabManagerForCallerNotification() else {
            return .tabManagerUnavailable
        }

        let normalizedTTY = Self.normalizedTTYName(callerTTY)
        guard let target = Self.callerNotificationTarget(
            fallback: fallbackTabManager,
            preferredWorkspaceId: preferredWorkspaceID,
            preferredSurfaceId: preferredSurfaceID,
            callerTTY: normalizedTTY,
            preferTTY: preferTTY
        ) else {
            return .workspaceNotFound
        }
        deliverNotificationSynchronously(
            tabId: target.workspace.id,
            surfaceId: target.surfaceId,
            title: title,
            subtitle: subtitle,
            body: body
        )
        return .delivered(workspaceID: target.workspace.id, surfaceID: target.surfaceId)
    }

    private static func callerNotificationTarget(
        fallback: TabManager,
        preferredWorkspaceId: UUID?,
        preferredSurfaceId: UUID?,
        callerTTY: String?,
        preferTTY: Bool
    ) -> TerminalCallerNotificationTarget? {
        let managers = candidateManagers(
            fallback: fallback,
            preferredWorkspaceId: preferredWorkspaceId,
            preferredSurfaceId: preferredSurfaceId
        )
        let ttyTarget = callerTTY.flatMap { targetForTTY($0, tabManagers: managers) }
        if preferTTY, let ttyTarget { return ttyTarget }

        if let preferredWorkspaceId,
           let workspace = workspace(id: preferredWorkspaceId, tabManagers: managers) {
            if let preferredSurfaceId, workspace.panels[preferredSurfaceId] != nil {
                return TerminalCallerNotificationTarget(workspace: workspace, surfaceId: preferredSurfaceId)
            }
            if let ttyTarget, ttyTarget.workspace.id == workspace.id { return ttyTarget }
            return TerminalCallerNotificationTarget(workspace: workspace, surfaceId: workspace.focusedPanelId)
        }

        if let ttyTarget { return ttyTarget }
        if let preferredSurfaceId,
           let surfaceTarget = targetForSurface(preferredSurfaceId, tabManagers: managers) {
            return surfaceTarget
        }
        if let preferredSurfaceId,
           let selected = selectedWorkspace(in: managers),
           selected.panels[preferredSurfaceId] != nil {
            return TerminalCallerNotificationTarget(workspace: selected, surfaceId: preferredSurfaceId)
        }
        guard let selected = selectedWorkspace(in: managers) else { return nil }
        return TerminalCallerNotificationTarget(workspace: selected, surfaceId: selected.focusedPanelId)
    }

    private static func candidateManagers(
        fallback: TabManager,
        preferredWorkspaceId: UUID?,
        preferredSurfaceId: UUID?
    ) -> [TabManager] {
        var managers: [TabManager] = []
        func append(_ manager: TabManager?) {
            guard let manager, !managers.contains(where: { $0 === manager }) else { return }
            managers.append(manager)
        }

        let app = AppDelegate.shared
        if let preferredWorkspaceId { append(app?.tabManagerFor(tabId: preferredWorkspaceId)) }
        if let preferredSurfaceId { append(app?.locateSurface(surfaceId: preferredSurfaceId)?.tabManager) }
        append(fallback)
        app?.listMainWindowSummaries().forEach { append(app?.tabManagerFor(windowId: $0.windowId)) }
        return managers
    }

    private static func workspace(id: UUID, tabManagers: [TabManager]) -> Workspace? {
        for manager in tabManagers {
            if let workspace = manager.tabs.first(where: { $0.id == id }) { return workspace }
        }
        return nil
    }

    private static func selectedWorkspace(in tabManagers: [TabManager]) -> Workspace? {
        for manager in tabManagers {
            if let selectedId = manager.selectedTabId,
               let workspace = manager.tabs.first(where: { $0.id == selectedId }) {
                return workspace
            }
        }
        return nil
    }

    private static func targetForTTY(
        _ ttyName: String,
        tabManagers: [TabManager]
    ) -> TerminalCallerNotificationTarget? {
        for manager in tabManagers {
            for workspace in manager.tabs {
                for (surfaceId, candidateTTY) in workspace.surfaceTTYNames
                    where workspace.panels[surfaceId] != nil && normalizedTTYName(candidateTTY) == ttyName {
                    return TerminalCallerNotificationTarget(workspace: workspace, surfaceId: surfaceId)
                }
            }
        }
        return nil
    }

    private static func targetForSurface(
        _ surfaceId: UUID,
        tabManagers: [TabManager]
    ) -> TerminalCallerNotificationTarget? {
        for manager in tabManagers {
            for workspace in manager.tabs where workspace.panels[surfaceId] != nil {
                return TerminalCallerNotificationTarget(workspace: workspace, surfaceId: surfaceId)
            }
        }
        return nil
    }

    private static func normalizedTTYName(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              trimmed != "not a tty" else {
            return nil
        }
        return trimmed.split(separator: "/").last.map(String.init) ?? trimmed
    }
}
