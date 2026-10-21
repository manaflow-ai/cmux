import CmuxNextActions
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
                               open: { [weak services] in services?.agentActivityPage.jump(to: $0) },
                               rowAction: { [weak services] action in
                                   if let services { SidebarPriorityRowActions.perform(action, in: services.registry) }
                               },
                               toggleShown: { [weak services] in _ = services?.registry.perform(Self.toggleAction, invocation: ActionInvocation(origin: .user)) }),
                  chats: .app)
    }

    /// Toggle Priority View flips `sidebar.priorityView.shown` while the view is installed.
    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        let preferences = { @MainActor @Sendable in context.services.settings?.snapshot.sidebarSections ?? .defaults }
        registry.bind(toggleAction, unavailable: { preferences().priorityViewEnabled ? nil : SidebarPriorityPanel.unavailableReason }) { _ in
            try AppearanceHandlers.requireUnmanaged(SidebarPriorityViewSetting.shownPath, context)
            context.writeSetting("toggle priority view", SidebarPriorityViewSetting.shownPath, .bool(!preferences().priorityViewShown))
        }
        SidebarPriorityRowActions(chats: .app, unavailable: { preferences().priorityViewEnabled ? nil : SidebarPriorityPanel.unavailableReason })
            .bind(into: registry)
    }
}
