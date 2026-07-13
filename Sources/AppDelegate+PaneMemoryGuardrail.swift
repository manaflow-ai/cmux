import Foundation

extension AppDelegate {
    /// Starts the per-pane runaway-memory guardrail and the central
    /// memory-pressure monitor. The pane guardrail keeps its existing
    /// process-tree accounting timer; global memory pressure is handled through
    /// responder registration so future reclaim paths are one conformance away.
    func startPaneMemoryGuardrailIfNeeded() {
        let guardrail = PaneMemoryGuardrail.shared
        guardrail.paneProvider = { [weak self] in
            self?.paneMemoryGuardrailDescriptors() ?? []
        }
        guardrail.start()
        startMemoryPressureMonitorIfNeeded()
    }

    func paneMemoryGuardrailDescriptors() -> [PaneMemoryDescriptor] {
        paneMemoryGuardrailTabManagers().flatMap { manager in
            manager.tabs.flatMap { workspace in
                paneMemoryGuardrailDescriptors(in: workspace)
            }
        }
    }

    private func startMemoryPressureMonitorIfNeeded() {
        let monitor = MemoryPressureMonitor.shared
        monitor.registry.register(
            RendererRealizationMemoryPressureResponder(
                controller: RendererRealizationController.shared
            )
        )
        monitor.registry.register(
            BrowserHiddenWebViewMemoryPressureResponder { [weak self] in
                self?.paneMemoryGuardrailTabManagers() ?? []
            }
        )
        if let notificationStore {
            monitor.registry.register(
                NotificationCacheMemoryPressureResponder(store: notificationStore)
            )
        }
        monitor.onPersistentCriticalPressure = { [weak self] snapshot in
            self?.postPersistentCriticalMemoryPressureWarning(snapshot: snapshot)
        }
        monitor.start()
    }

    private func postPersistentCriticalMemoryPressureWarning(snapshot: MemoryPressureSnapshot) {
        guard let notificationStore else { return }
        let managers = paneMemoryGuardrailTabManagers()
        guard let tabId = tabManager?.selectedTabId
            ?? managers.compactMap(\.selectedTabId).first
            ?? managers.flatMap(\.tabs).first?.id
        else { return }

        notificationStore.addNotification(
            tabId: tabId,
            surfaceId: nil,
            title: String(
                localized: "memoryPressure.critical.title",
                defaultValue: "cmux is under critical memory pressure"
            ),
            subtitle: String(
                localized: "memoryPressure.critical.subtitle",
                defaultValue: "Hidden renderers and browsers were released"
            ),
            body: String(
                localized: "memoryPressure.critical.body",
                defaultValue: "macOS is reporting sustained critical memory pressure. cmux has shed hidden resources; close idle workspaces or restart cmux if pressure continues."
            ),
            cooldownKey: "memory-pressure-critical",
            cooldownInterval: 300
        )
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
