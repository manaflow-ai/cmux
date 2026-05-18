import Foundation

@MainActor
private struct TerminalCallerNotificationTarget {
    let workspace: Workspace
    let surfaceId: UUID?
}

@MainActor
extension TerminalController {
    func v2NotificationCreateForCaller(params: [String: Any]) -> V2CallResult {
        guard let fallbackTabManager = activeTabManagerForCallerNotification() else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }

        let preferredWorkspaceId = v2UUID(params, "preferred_workspace_id")
        let preferredSurfaceId = v2UUID(params, "preferred_surface_id")
        let callerTTY = Self.normalizedTTYName(stringParam(params, "caller_tty"))
        let preferTTY = boolParam(params, "prefer_tty") ?? false
        let title = stringParam(params, "title") ?? "Notification"
        let subtitle = stringParam(params, "subtitle") ?? ""
        let body = stringParam(params, "body") ?? ""

        var result: V2CallResult = .err(code: "internal_error", message: "Failed to notify", data: nil)
        runOnMain {
            let target = Self.callerNotificationTarget(
                fallback: fallbackTabManager,
                preferredWorkspaceId: preferredWorkspaceId,
                preferredSurfaceId: preferredSurfaceId,
                callerTTY: callerTTY,
                preferTTY: preferTTY
            )
            guard let target else {
                result = .err(code: "not_found", message: "Workspace not found", data: nil)
                return
            }
            self.deliverNotificationSynchronously(
                tabId: target.workspace.id,
                surfaceId: target.surfaceId,
                title: title,
                subtitle: subtitle,
                body: body
            )
            let surfaceId: Any = target.surfaceId?.uuidString ?? NSNull()
            result = .ok([
                "workspace_id": target.workspace.id.uuidString,
                "surface_id": surfaceId
            ])
        }
        return result
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

    private func stringParam(_ params: [String: Any], _ key: String) -> String? {
        guard let raw = params[key] as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func boolParam(_ params: [String: Any], _ key: String) -> Bool? {
        if let value = params[key] as? Bool { return value }
        if let value = params[key] as? NSNumber { return value.boolValue }
        switch stringParam(params, key)?.lowercased() {
        case "1", "true", "yes", "on": return true
        case "0", "false", "no", "off": return false
        default: return nil
        }
    }

    private static func normalizedTTYName(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              trimmed != "not a tty" else {
            return nil
        }
        return trimmed.split(separator: "/").last.map(String.init) ?? trimmed
    }

    private func runOnMain(_ body: @escaping () -> Void) {
        if Thread.isMainThread {
            body()
        } else {
            DispatchQueue.main.sync(execute: body)
        }
    }
}
