import Foundation

@MainActor
private struct TerminalCallerTarget {
    let workspace: Workspace
    let surfaceId: UUID?
}

@MainActor
extension TerminalController {
    func v2IdentifyCallerPayload(
        workspace: Workspace,
        surfaceId: UUID?,
        tabManager: TabManager
    ) -> [String: Any]? {
        let callerWindowId = v2ResolveWindowId(tabManager: tabManager)
        var payload: [String: Any] = [
            "window_id": v2OrNull(callerWindowId?.uuidString),
            "window_ref": v2Ref(kind: .window, uuid: callerWindowId),
            "workspace_id": workspace.id.uuidString,
            "workspace_ref": v2Ref(kind: .workspace, uuid: workspace.id),
        ]

        if let surfaceId {
            guard let target = workspace.controlSurfaceTarget(for: surfaceId) else { return nil }
            payload["surface_id"] = target.surfaceID.uuidString
            payload["surface_ref"] = v2Ref(kind: .surface, uuid: target.surfaceID)
            payload["tab_id"] = target.surfaceID.uuidString
            payload["tab_ref"] = v2TabRef(uuid: target.surfaceID)
            payload["surface_type"] = target.panel.panelType.rawValue
            payload["is_browser_surface"] = target.panel.panelType == .browser
            payload["pane_id"] = v2OrNull(target.paneID?.uuidString)
            payload["pane_ref"] = v2Ref(kind: .pane, uuid: target.paneID)
        } else {
            payload["surface_id"] = NSNull()
            payload["surface_ref"] = NSNull()
            payload["tab_id"] = NSNull()
            payload["tab_ref"] = NSNull()
            payload["surface_type"] = NSNull()
            payload["is_browser_surface"] = NSNull()
            payload["pane_id"] = NSNull()
            payload["pane_ref"] = NSNull()
        }
        return payload
    }

    func v2IdentifyCallerPayload(
        callerTTY: String,
        fallbackTabManager: TabManager
    ) -> [String: Any]? {
        let managers = Self.candidateManagers(
            fallback: fallbackTabManager,
            preferredWorkspaceId: nil,
            preferredSurfaceId: nil
        )
        guard let target = liveTargetForTTY(callerTTY, tabManagers: managers),
              let owningManager = managers.first(where: { manager in
                  manager.tabs.contains(where: { $0 === target.workspace })
              }) else {
            return nil
        }
        return v2IdentifyCallerPayload(
            workspace: target.workspace,
            surfaceId: target.surfaceId,
            tabManager: owningManager
        )
    }

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
    ) -> TerminalCallerTarget? {
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
                return TerminalCallerTarget(workspace: workspace, surfaceId: preferredSurfaceId)
            }
            // Moved pane (issue #7939): the explicit surface identity outranks
            // the stale spawn-time workspace claim — follow the surface to the
            // workspace that owns it NOW instead of falling back to the old
            // workspace's focused pane.
            if let preferredSurfaceId,
               let surfaceTarget = targetForSurface(preferredSurfaceId, tabManagers: managers) {
                return surfaceTarget
            }
            if let ttyTarget, ttyTarget.workspace.id == workspace.id { return ttyTarget }
            return TerminalCallerTarget(workspace: workspace, surfaceId: workspace.focusedPanelId)
        }

        if let ttyTarget { return ttyTarget }
        if let preferredSurfaceId,
           let surfaceTarget = targetForSurface(preferredSurfaceId, tabManagers: managers) {
            return surfaceTarget
        }
        if let preferredSurfaceId,
           let selected = selectedWorkspace(in: managers),
           selected.panels[preferredSurfaceId] != nil {
            return TerminalCallerTarget(workspace: selected, surfaceId: preferredSurfaceId)
        }
        guard let selected = selectedWorkspace(in: managers) else { return nil }
        return TerminalCallerTarget(workspace: selected, surfaceId: selected.focusedPanelId)
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
    ) -> TerminalCallerTarget? {
        for manager in tabManagers {
            for workspace in manager.tabs {
                for (surfaceId, candidateTTY) in workspace.surfaceTTYNames
                    where workspace.panels[surfaceId] != nil && normalizedTTYName(candidateTTY) == ttyName {
                    return TerminalCallerTarget(workspace: workspace, surfaceId: surfaceId)
                }
            }
        }
        return nil
    }

    /// Resolve local callers from Ghostty's current runtime PTYs first. Shell-
    /// reported TTYs are a unique-only fallback for nested multiplexers such as
    /// tmux, where the pane TTY necessarily differs from Ghostty's outer PTY.
    private func liveTargetForTTY(
        _ ttyName: String,
        tabManagers: [TabManager]
    ) -> TerminalCallerTarget? {
        var liveCandidates: [(binding: TerminalCallerTTYBinding, ttyName: String)] = []
        var reportedCandidates: [(binding: TerminalCallerTTYBinding, ttyName: String)] = []
        var targets: [TerminalCallerTTYBinding: TerminalCallerTarget] = [:]
        for manager in tabManagers {
            for workspace in manager.tabs {
                guard !workspace.isRemoteWorkspace, !workspace.isRemoteTmuxMirror else { continue }
                for (surfaceId, panel) in workspace.panels {
                    guard let terminalPanel = panel as? TerminalPanel,
                          !workspace.isRemoteTerminalSurface(surfaceId) else { continue }
                    let binding = TerminalCallerTTYBinding(
                        workspaceId: workspace.id,
                        surfaceId: surfaceId
                    )
                    targets[binding] = TerminalCallerTarget(
                        workspace: workspace,
                        surfaceId: surfaceId
                    )
                    if let liveTTYName = terminalPanel.surface.controllingTTYName() {
                        liveCandidates.append((binding: binding, ttyName: liveTTYName))
                    }
                    if let reportedTTYName = workspace.surfaceTTYNames[surfaceId],
                       portScanner.freshReportedTTYName(
                           workspaceId: workspace.id,
                           panelId: surfaceId
                       ) == reportedTTYName {
                        reportedCandidates.append((binding: binding, ttyName: reportedTTYName))
                    }
                }
            }
        }
        let resolver = TerminalCallerTTYResolver(
            liveCandidates: liveCandidates,
            reportedCandidates: reportedCandidates
        )
        guard let binding = resolver.binding(for: ttyName) else {
            return nil
        }
        return targets[binding]
    }

    private static func targetForSurface(
        _ surfaceId: UUID,
        tabManagers: [TabManager]
    ) -> TerminalCallerTarget? {
        for manager in tabManagers {
            for workspace in manager.tabs where workspace.panels[surfaceId] != nil {
                return TerminalCallerTarget(workspace: workspace, surfaceId: surfaceId)
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
        TerminalCallerTTYResolver.normalizedName(raw)
    }

    private func runOnMain(_ body: @escaping () -> Void) {
        if Thread.isMainThread {
            body()
        } else {
            DispatchQueue.main.sync(execute: body)
        }
    }
}
