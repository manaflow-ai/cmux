import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextDaemonService

/// The right sidebar's actions (inventory row 24): Toggle Right Sidebar, Focus
/// Right Sidebar and its section switches, on the active window. Each shows
/// the sidebar; the Files and Find switches stay with the file explorer
/// (`SidebarHandlers`) until it registers those sections.
enum RightSidebarHandlers {
    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        registry.bind("toggleRightSidebar", run: { invocation in
            try AgentChatSideColumn().toggle(invocation, unavailable: { RefusalStrings.needsAppCapability("right-sidebar") }, focused: { context.scope($0).pane }, panes: { context.services.windows.active?.content?.panes.values.map { $0 } ?? [] },
                                             chat: { $0.currentTabKey.flatMap { context.services.agentTabs.isNewTabPage($0) ? nil : context.services.agentTabs.existingView($0) } }, left: { $0.view.convert($0.view.bounds, to: nil).minX }, refuse: { context.refuse($0) }, fallback: { _ in try window(context).toggleRightSidebar() })
        })
        registry.bind("focusRightSidebar", run: { invocation in
            let controller = try window(context)
            guard controller.showRightSidebar(focus: invocation.allowsViewChange) else { throw ActionFailure.needsAppCapability("right-sidebar") }
        })
        for mode in [RightSidebarMode.sessions, .feed, .dock, .machines] {
            registry.bind(mode.actionID, run: { invocation in
                let controller = try window(context)
                guard controller.showRightSidebar(mode, focus: invocation.allowsViewChange) else {
                    throw ActionFailure.needsAppCapability("right-sidebar")
                }
            })
        }
    }

    private static func window(_ context: AppActionContext) throws -> WindowController {
        guard let controller = context.activeWindow else { throw ActionFailure(message: RefusalStrings.noWindowOpen) }
        return controller
    }
}
