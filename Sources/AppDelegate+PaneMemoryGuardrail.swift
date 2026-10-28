import CmuxNotifications
import Foundation

extension AppDelegate {
    /// The app-owned warning model for runaway terminal sessions.
    var runawayPaneWarningCenter: RunawayPaneWarningCenter {
        PaneMemoryGuardrail.shared.runawayWarningCenter
    }

    /// Starts the per-pane runaway-memory guardrail and the central
    /// memory-pressure monitor. The pane guardrail keeps its existing
    /// process-tree accounting timer; global pressure is handled through
    /// responder registration. Aggregate pressure is intentionally isolated to
    /// its idle-agent-hibernation responder. Resource diagnostics never enter
    /// the user notification pipeline; the one exception is the runaway
    /// terminal warning, which posts without hooks or notification commands.
    func startPaneMemoryGuardrailIfNeeded() {
        let guardrail = PaneMemoryGuardrail.shared
        guardrail.paneProvider = { [weak self] in
            self?.paneMemoryGuardrailDescriptors() ?? []
        }
        guardrail.start()
        startMemoryPressureMonitorIfNeeded()
    }

    func paneMemoryGuardrailDescriptors() -> [PaneMemoryDescriptor] {
        var descriptors: [PaneMemoryDescriptor] = []
        var seenKeys: Set<PaneMemoryPaneKey> = []

        func append(_ candidates: [PaneMemoryDescriptor]) {
            for descriptor in candidates where seenKeys.insert(descriptor.key).inserted {
                descriptors.append(descriptor)
            }
        }

        for manager in paneMemoryGuardrailTabManagers() {
            for workspace in manager.tabs {
                append(paneMemoryGuardrailDescriptors(in: workspace))
                if let dock = workspace._dockSplit {
                    append(paneMemoryGuardrailDescriptors(in: dock, workspaceTitle: workspace.title))
                }
            }
        }
        for dock in existingWindowDocks {
            append(paneMemoryGuardrailDescriptors(
                in: dock,
                workspaceTitle: String(localized: "dock.source.title", defaultValue: "Dock")
            ))
        }
        return descriptors
    }

    func startMemoryPressureMonitorIfNeeded() {
        let monitor = MemoryPressureMonitor.shared
        monitor.registry.register(
            RendererRealizationMemoryPressureResponder(
                controller: RendererRealizationController.shared
            )
        )
        monitor.registry.register(
            BrowserHiddenWebViewMemoryPressureResponder { [weak self] in
                self?.allLiveBrowserPanels() ?? []
            }
        )
        monitor.registry.register(
            AggregateMemoryPressureResponder(
                controller: AgentHibernationController.shared,
                isAggregatePressureActive: { [weak monitor] in
                    guard let aggregate = monitor?.aggregateMemoryPressure else { return false }
                    return aggregate.isActionable && aggregate.severity >= .warning
                }
            )
        )
        monitor.registry.register(
            RunawayPaneTreeMemoryPressureResponder { [weak self] in
                self?.paneMemoryGuardrailDescriptors() ?? []
            }
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
        monitor.onAggregatePressureCleared = {
            AgentHibernationController.shared.clearAggregateMemoryPressureConfirmations()
        }
        let browserMemoryBudget = BrowserHiddenWebViewMemoryBudgetCoordinator { [weak self] in
            self?.allLiveBrowserPanels() ?? []
        }
        let runawayWarnings = runawayPaneWarningCenter
        runawayWarnings.paneProvider = { [weak self] in
            self?.paneMemoryGuardrailDescriptors() ?? []
        }
        runawayWarnings.onNewWarning = { [weak self] warning in
            self?.postRunawayPaneWarningNotification(warning)
        }
        monitor.onSampleApplied = { sampledAt in
            browserMemoryBudget.enforceBudget(now: sampledAt)
            // A system pressure event measures right away, between ticks.
            runawayWarnings.evaluate()
        }
        runawayWarnings.start()
        monitor.start()
    }

    /// Posts the runaway-terminal warning as a notification on that pane, so
    /// it reaches the user while cmux is in the background. Clicking it opens
    /// the terminal, where the banner offers Stop Process Tree.
    private func postRunawayPaneWarningNotification(_ warning: RunawayPaneWarning) {
        guard notificationSurfaceOwner(
            surfaceID: warning.panelId,
            preferredTabID: warning.workspaceId
        ) != nil else { return }
        notificationStore?.addNotification(
            tabId: warning.workspaceId,
            surfaceId: warning.panelId,
            title: String(
                localized: "runawayPaneWarning.title",
                defaultValue: "A terminal's processes are running away"
            ),
            subtitle: warning.locationText,
            body: String.localizedStringWithFormat(
                String(
                    localized: "runawayPaneWarning.notification.body",
                    defaultValue: "%@. Open the terminal to stop its process tree."
                ),
                warning.detailText
            ),
            cooldownKey: "runaway-pane-tree.\(warning.panelId.uuidString)",
            cooldownInterval: 300,
            // Hooks and notification commands spawn processes, which can fail
            // or add load while the process table or memory is exhausted.
            resolvedHooks: [],
            effects: TerminalNotificationPolicyEffectsPatch(command: false)
        )
    }

    /// Every live browser panel, each once: workspace panes plus the panes of
    /// workspace and window Docks.
    func allLiveBrowserPanels() -> [BrowserPanel] {
        var panels: [BrowserPanel] = []
        var seen: Set<ObjectIdentifier> = []

        func append(_ panel: any Panel) {
            guard let browserPanel = panel as? BrowserPanel,
                  seen.insert(ObjectIdentifier(browserPanel)).inserted else { return }
            panels.append(browserPanel)
        }

        for manager in paneMemoryGuardrailTabManagers() {
            for workspace in manager.tabs {
                workspace.panels.values.forEach(append)
                workspace._dockSplit?.forEachPanel { _, panel in append(panel) }
            }
        }
        for dock in existingWindowDocks {
            dock.forEachPanel { _, panel in append(panel) }
        }
        return panels
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
            paneMemoryGuardrailDescriptor(
                for: panel,
                workspaceId: workspace.id,
                workspaceTitle: workspace.title
            )
        }
    }

    private func paneMemoryGuardrailDescriptors(
        in dock: DockSplitStore,
        workspaceTitle: String
    ) -> [PaneMemoryDescriptor] {
        var descriptors: [PaneMemoryDescriptor] = []
        dock.forEachPanel { _, panel in
            if let descriptor = paneMemoryGuardrailDescriptor(
                for: panel,
                workspaceId: dock.workspaceId,
                workspaceTitle: workspaceTitle
            ) {
                descriptors.append(descriptor)
            }
        }
        return descriptors
    }

    private func paneMemoryGuardrailDescriptor(
        for panel: any Panel,
        workspaceId: UUID,
        workspaceTitle: String
    ) -> PaneMemoryDescriptor? {
        guard let terminalPanel = panel as? TerminalPanel else { return nil }
        let surface = terminalPanel.surface
        let hasLiveSurface = surface.hasLiveSurface
        let ttyName = hasLiveSurface ? surface.controllingTTYName()?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            : nil
        return PaneMemoryDescriptor(
            workspaceId: workspaceId,
            panelId: terminalPanel.id,
            workspaceTitle: workspaceTitle,
            paneTitle: terminalPanel.displayTitle,
            ttyName: ttyName?.isEmpty == false ? ttyName : nil,
            foregroundPID: hasLiveSurface ? surface.foregroundProcessID() : nil
        )
    }
}
