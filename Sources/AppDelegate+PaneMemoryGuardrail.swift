import Foundation

extension AppDelegate {
    /// Starts the per-pane runaway-memory guardrail and the central
    /// memory-pressure monitor. The pane guardrail keeps its existing
    /// process-tree accounting timer; global pressure is handled through
    /// responder registration. Aggregate pressure is intentionally isolated to
    /// its warning plus idle-agent-hibernation responder.
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
        monitor.registry.register(
            AggregateMemoryPressureResponder(
                controller: AgentHibernationController.shared,
                isAggregatePressureActive: { [weak monitor] in
                    guard let aggregate = monitor?.aggregateMemoryPressure else { return false }
                    return aggregate.isActionable && aggregate.severity >= .warning
                },
                onAggregatePressureWarning: { [weak self] _ in
                    self?.postAggregateMemoryPressureWarning()
                }
            )
        )
        monitor.registry.register(
            AgentHibernationMemoryPressureResponder(
                controller: AgentHibernationController.shared,
                isPressureCritical: { [weak monitor] in
                    monitor?.currentSeverity == .critical
                }
            )
        )
        if let notificationStore {
            monitor.registry.register(
                NotificationCacheMemoryPressureResponder(store: notificationStore)
            )
        }
        monitor.onPersistentCriticalPressure = { [weak self] snapshot in
            self?.postPersistentCriticalMemoryPressureWarning(snapshot: snapshot)
        }
        monitor.onAggregatePressureCleared = {
            AgentHibernationController.shared.clearAggregateMemoryPressureConfirmations()
        }
        monitor.start()
    }

    private func postAggregateMemoryPressureWarning() {
        guard let notificationStore else { return }
        let managers = paneMemoryGuardrailTabManagers()
        guard let tabId = tabManager?.selectedTabId
            ?? managers.lazy.compactMap { $0.selectedTabId }.first
            ?? managers.lazy.compactMap { $0.tabs.first?.id }.first
        else { return }

        notificationStore.addNotification(
            tabId: tabId,
            surfaceId: nil,
            title: String(
                localized: "memoryPressure.aggregate.title",
                defaultValue: "cmux is using substantial aggregate memory"
            ),
            subtitle: String(
                localized: "memoryPressure.aggregate.subtitle",
                defaultValue: "Idle agent surfaces may be hibernated"
            ),
            body: String(
                localized: "memoryPressure.aggregate.body",
                defaultValue: "macOS reports memory pressure across cmux and its child processes. Only hidden, idle agent surfaces are considered after a confirmation window; active or visible work is left alone."
            ),
            cooldownKey: "memory-pressure-aggregate",
            cooldownInterval: 300
        )
    }

    private func postPersistentCriticalMemoryPressureWarning(snapshot: MemoryPressureSnapshot) {
        guard let notificationStore else { return }
        let managers = paneMemoryGuardrailTabManagers()
        guard let tabId = tabManager?.selectedTabId
            ?? managers.compactMap({ $0.selectedTabId }).first
            ?? managers.flatMap({ $0.tabs }).first?.id
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
