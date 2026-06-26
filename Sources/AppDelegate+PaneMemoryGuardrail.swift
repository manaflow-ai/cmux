import Foundation

extension AppDelegate {
    /// Posts a calm, per-pane in-app notification for each pane that just crossed
    /// the runaway-memory threshold (issue #6313). Reuses the standard
    /// `TerminalNotificationStore` channel — the same one agent and crash
    /// notifications use — so it drives the existing unread indicator and
    /// click-to-navigate to the offending pane without the bespoke sidebar badge
    /// and dismissible "kill pane" banner that issue #6614 removed. A per-pane
    /// cooldown keeps a flapping leak from spamming the notification list.
    func presentPaneMemoryRunawayNotifications(_ warnings: [PaneMemoryWarning]) {
        guard let notificationStore else { return }
        for warning in warnings {
            let content = PaneMemoryGuardrailNotification.content(for: warning)
            notificationStore.addNotification(
                tabId: warning.workspaceId,
                surfaceId: warning.panelId,
                title: content.title,
                subtitle: content.subtitle,
                body: content.body,
                cooldownKey: content.cooldownKey,
                cooldownInterval: PaneMemoryGuardrailNotification.cooldownInterval
            )
        }
    }

    func paneMemoryGuardrailDescriptors() -> [PaneMemoryDescriptor] {
        paneMemoryGuardrailTabManagers().flatMap { manager in
            manager.tabs.flatMap { workspace in
                paneMemoryGuardrailDescriptors(in: workspace)
            }
        }
    }

    func discardHiddenBrowserWebViewsForSystemMemoryPressure() {
        let now = Date()
        let discardedCount = paneMemoryGuardrailTabManagers().reduce(0) { count, manager in
            count + manager.discardHiddenBrowserWebViewsForSystemMemoryPressure(now: now)
        }
#if DEBUG
        cmuxDebugLog("browser.memoryPressure.discardHidden count=\(discardedCount)")
#endif
    }

    private func paneMemoryGuardrailTabManagers() -> [TabManager] {
        var managers: [TabManager] = []
        var seen: Set<ObjectIdentifier> = []

        func append(_ manager: TabManager?) {
            guard let manager else { return }
            let id = ObjectIdentifier(manager)
            guard seen.insert(id).inserted else { return }
            managers.append(manager)
        }

        for context in mainWindowContexts.values {
            append(context.tabManager)
        }
        for route in recoverableMainWindowRoutes() {
            append(route.tabManager)
        }
        append(tabManager)
        return managers
    }

    private func paneMemoryGuardrailDescriptors(in workspace: Workspace) -> [PaneMemoryDescriptor] {
        workspace.panels.values.compactMap { panel in
            guard let terminalPanel = panel as? TerminalPanel else { return nil }
            let surface = terminalPanel.surface
            let hasLiveSurface = surface.hasLiveSurface
            let ttyName = hasLiveSurface ? surface.controllingTTYName()?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                : nil
            return PaneMemoryDescriptor(
                workspaceId: workspace.id,
                panelId: terminalPanel.id,
                workspaceTitle: workspace.title,
                paneTitle: terminalPanel.displayTitle,
                ttyName: ttyName?.isEmpty == false ? ttyName : nil,
                foregroundPID: hasLiveSurface ? surface.foregroundProcessID() : nil
            )
        }
    }
}
