import CmuxNextActions
import CmuxNextAgentActivity
import CmuxNextAgentLanes
import CmuxNextDesign
import CmuxNextSettings
import CmuxNextSidebar

/// The Priority view's wiring (the feed lives in CmuxNextAgentLanes): the settings, the Toggle
/// Priority View action and shortcut, the chat jump and the rows' actions
/// (`SidebarPriorityRowActions`), which its hover buttons run through the registry.
extension SidebarPriorityFeed {
    static let toggleAction: ActionID = "sidebar.priorityView.toggle"

    convenience init(services: AppServices) {
        let preferences = { DesignSettings.shared.sidebarSections }
        self.init(settings: Settings(enabled: { preferences().priorityViewEnabled }, shown: { preferences().priorityViewShown }),
                  hooks: Hooks(shortcut: { [weak services] in services?.registry.shortcutDisplay(for: Self.toggleAction) },
                               open: { [weak services] lane in if let services { Self.open(lane, services: services) } },
                               rowAction: { [weak services] action in
                                   if let services { SidebarPriorityRowActions.perform(action, in: services.registry) }
                               },
                               toggleShown: { [weak services] in _ = services?.registry.perform(Self.toggleAction, invocation: ActionInvocation(origin: .user)) },
                               openedSessions: { [weak services] in
                                   guard let tabs = services?.agentTabs else { return [] }
                                   return Set(tabs.listTabs().compactMap { tabs.sessions[$0.key] ?? $0.record.session })
                               }),
                  chats: .app)
    }

    /// Opens a row's chat: the tab that shows it here, else the tab of the other machine's tree
    /// the row came from (its chat runs there), else a new tab here (the `cmux://session/<id>` path).
    private static func open(_ lane: AgentActivityLane, services: AppServices) {
        if services.agentTabs.tab(showing: lane.id) == nil, let tab = AgentPriorityChats.app.remoteTab(showing: lane.id),
           services.revealTab(tab) { return }
        services.agentActivityPage.jump(to: lane)
    }

    /// Toggle Priority View flips `sidebar.priorityView.shown` while the view is installed.
    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        let preferences = { @MainActor @Sendable in context.services.settings?.snapshot.sidebarSections ?? .defaults }
        registry.bind(toggleAction, unavailable: { preferences().priorityViewEnabled ? nil : SidebarPriorityPanel.unavailableReason }) { _ in
            try AppearanceHandlers.requireUnmanaged(SidebarPriorityViewSetting.shownPath, context)
            context.writeSetting("toggle priority view", SidebarPriorityViewSetting.shownPath, .bool(!preferences().priorityViewShown))
        }
        let machines = context.services.machines
        AgentPriorityChats.app.machines = .init(remote: { [weak machines] in machines?.priorityMachines ?? [] },
                                                peer: { [weak machines] in machines?.machineName(peer: $0) },
                                                // This Mac's rows gain its name with `sidebar.showLocalMachine` (#22763).
                                                local: { nil })
        SidebarPriorityRowActions(chats: .app, unavailable: { preferences().priorityViewEnabled ? nil : SidebarPriorityPanel.unavailableReason })
            .bind(into: registry)
    }
}
