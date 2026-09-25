import CmuxNotifications
import Foundation

@MainActor
private struct TerminalCallerTarget {
    let workspace: Workspace
    let surfaceId: UUID?
}

/// Resolved caller-notification address, shared across the entrypoints of
/// `resolvedCallerNotificationTarget`. Carries identities only so callers
/// outside this file never hold live `Workspace` references.
struct TerminalCallerNotificationTarget: Sendable {
    let workspaceId: UUID
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
        guard let target = Self.liveTargetForTTY(callerTTY, tabManagers: managers),
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
        guard activeTabManagerForCallerNotification() != nil else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }

        let preferredWorkspaceId = v2UUID(params, "preferred_workspace_id")
        // Old clients do not send the provenance bit; preserve their moved-
        // surface behavior and treat the workspace claim as ambient. New CLI
        // callers set it explicitly when `--workspace` was supplied.
        let preferredWorkspaceIsExplicit = boolParam(params, "preferred_workspace_is_explicit") ?? false
        let preferredSurfaceId = v2UUID(params, "preferred_surface_id")
        let callerTTY = stringParam(params, "caller_tty")
        let preferTTY = boolParam(params, "prefer_tty") ?? false
        let title = stringParam(params, "title") ?? "Notification"
        let subtitle = stringParam(params, "subtitle") ?? ""
        let body = stringParam(params, "body") ?? ""
        let replyShape = TerminalNotificationReplyShape(wire: stringParam(params, "reply_shape"))

        var result: V2CallResult = .err(code: "internal_error", message: "Failed to notify", data: nil)
        runOnMain {
            let target = self.resolvedCallerNotificationTarget(
                preferredWorkspaceId: preferredWorkspaceId,
                preferredSurfaceId: preferredSurfaceId,
                callerTTY: callerTTY,
                preferTTY: preferTTY,
                preferredWorkspaceIsExplicit: preferredWorkspaceIsExplicit
            )
            guard let target else {
                result = .err(code: "not_found", message: "Workspace not found", data: nil)
                return
            }
            let notificationID = self.deliverNotificationSynchronously(
                tabId: target.workspaceId,
                surfaceId: target.surfaceId,
                title: title,
                subtitle: subtitle,
                body: body,
                replyShape: replyShape
            )
            let surfaceId: Any = target.surfaceId?.uuidString ?? NSNull()
            let payload: [String: Any] = [
                "workspace_id": target.workspaceId.uuidString,
                "surface_id": surfaceId,
                "id": notificationID?.uuidString ?? NSNull(),
            ]
            result = .ok(payload)
        }
        return result
    }

    /// Shared caller-target resolution entrypoint: the workspace/surface a
    /// caller-addressed notification should land on, resolved with the same
    /// TTY/preference/moved-pane rules for every entrypoint that needs it
    /// (`notification.create_for_caller` above; the notification debug
    /// emitter's target resolution in DEBUG builds).
    func resolvedCallerNotificationTarget(
        preferredWorkspaceId: UUID?,
        preferredSurfaceId: UUID?,
        callerTTY: String?,
        preferTTY: Bool,
        preferredWorkspaceIsExplicit: Bool = true
    ) -> TerminalCallerNotificationTarget? {
        guard let fallback = activeTabManagerForCallerNotification() else { return nil }
        guard let target = Self.callerNotificationTarget(
            fallback: fallback,
            preferredWorkspaceId: preferredWorkspaceId,
            preferredSurfaceId: preferredSurfaceId,
            callerTTY: Self.normalizedTTYName(callerTTY),
            preferTTY: preferTTY,
            preferredWorkspaceIsExplicit: preferredWorkspaceIsExplicit
        ) else { return nil }
        return TerminalCallerNotificationTarget(
            workspaceId: target.workspace.id,
            surfaceId: target.surfaceId
        )
    }

    private static func callerNotificationTarget(
        fallback: TabManager,
        preferredWorkspaceId: UUID?,
        preferredSurfaceId: UUID?,
        callerTTY: String?,
        preferTTY: Bool,
        preferredWorkspaceIsExplicit: Bool
    ) -> TerminalCallerTarget? {
        let managers = candidateManagers(
            fallback: fallback,
            preferredWorkspaceId: preferredWorkspaceId,
            preferredSurfaceId: preferredSurfaceId
        )
        let preferredSurfaceTarget = preferredSurfaceId.flatMap {
            targetForSurface($0, tabManagers: managers)
        }
        var didResolveTTY = false
        var cachedTTYTarget: TerminalCallerTarget?
        func resolveTTYTarget() -> TerminalCallerTarget? {
            guard !didResolveTTY else { return cachedTTYTarget }
            didResolveTTY = true
            cachedTTYTarget = callerTTY.flatMap { liveTargetForTTY($0, tabManagers: managers) }
            return cachedTTYTarget
        }
        if let preferredWorkspaceId,
           let workspace = workspace(id: preferredWorkspaceId, tabManagers: managers) {
            // An explicit workspace selector is a hard scope. An ambient
            // surface claim can belong to a different workspace after a pane
            // move; do not let that claim override the requested workspace.
            // A surface identity still outranks TTY evidence when it resolves
            // inside the requested workspace.
            if let preferredSurfaceTarget,
               (!preferredWorkspaceIsExplicit || preferredSurfaceTarget.workspace.id == workspace.id) {
                return preferredSurfaceTarget
            }
            let ttyTarget = resolveTTYTarget()
            if let ttyTarget, ttyTarget.workspace.id == workspace.id { return ttyTarget }
            // The workspace itself is still a valid delivery scope, but no
            // pane has been proven. Keep the notification workspace-level
            // instead of borrowing mutable focus state.
            return TerminalCallerTarget(workspace: workspace, surfaceId: nil)
        }

        // An explicit workspace selector that no longer resolves is a hard
        // scope failure. Never let a globally resolvable surface or TTY cross
        // that boundary after the workspace disappears.
        if preferredWorkspaceIsExplicit, preferredWorkspaceId != nil {
            return nil
        }

        // With no live workspace selector, a stable surface UUID is stronger
        // than an ordinary (non-preferred) TTY claim and may re-home a pane
        // after a workspace move.
        if let preferredSurfaceTarget { return preferredSurfaceTarget }

        // `prefer_tty` is an explicit caller contract used by tmux/PTY
        // wrappers. At this point there is no stronger pane identity or
        // explicit workspace scope left to protect, so a proven TTY may win.
        if preferTTY, let ttyTarget = resolveTTYTarget() { return ttyTarget }
        let ttyTarget = resolveTTYTarget()
        if let ttyTarget { return ttyTarget }

        // A supplied caller TTY or surface that did not resolve is an
        // attribution failure. With no authoritative pane (and no valid
        // workspace claim), selecting the focused workspace would still be a
        // guess and can put the ring on an unrelated pane.
        guard preferredWorkspaceId == nil, preferredSurfaceId == nil, callerTTY == nil else {
            return nil
        }
        guard let selected = selectedWorkspace(in: managers) else { return nil }
        // A selector-free caller may still receive a workspace-level
        // notification, but it must never inherit the workspace's focused
        // surface as if that were pane evidence.
        return TerminalCallerTarget(workspace: selected, surfaceId: nil)
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

    /// Resolve local callers from Ghostty's current runtime PTYs first. Shell-
    /// reported TTYs are a unique-only fallback for nested multiplexers such as
    /// tmux, where the pane TTY necessarily differs from Ghostty's outer PTY.
    private static func liveTargetForTTY(
        _ ttyName: String,
        tabManagers: [TabManager]
    ) -> TerminalCallerTarget? {
        guard let callerTTY = normalizedTTYName(ttyName) else { return nil }
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
                    // Restored TTY metadata is display context only. Include a
                    // shell-reported name in the resolver only while this
                    // terminal generation has an explicit runtime report;
                    // otherwise stale duplicate names can shadow the live pane.
                    if let reportedTTYName = workspace.surfaceTTYNames[surfaceId],
                       workspace.hasCurrentRuntimeReportedTTY(
                           panelId: surfaceId,
                           terminal: terminalPanel
                       ) {
                        reportedCandidates.append((binding: binding, ttyName: reportedTTYName))
                    }
                }
            }
        }
        let resolver = TerminalCallerTTYResolver(
            liveCandidates: liveCandidates,
            reportedCandidates: reportedCandidates
        )
        guard let binding = resolver.binding(for: callerTTY),
              let target = targets[binding] else {
            return nil
        }
        let resolvedFromLiveTTY = liveCandidates.contains { candidate in
            candidate.binding == binding && normalizedTTYName(candidate.ttyName) == callerTTY
        }
        if resolvedFromLiveTTY {
            return target
        }

        guard normalizedTTYName(PortScanner.shared.freshReportedTTYName(
            workspaceId: binding.workspaceId,
            panelId: binding.surfaceId
        )) == callerTTY else {
            return nil
        }
        return target
    }

    private static func targetForSurface(
        _ surfaceId: UUID,
        tabManagers: [TabManager]
    ) -> TerminalCallerTarget? {
        for manager in tabManagers {
            for workspace in manager.tabs {
                guard let target = workspace.surfaceOwnershipTarget(for: surfaceId) else {
                    continue
                }
                return TerminalCallerTarget(workspace: workspace, surfaceId: target.surfaceID)
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
