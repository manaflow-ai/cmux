import CmuxNextActions
import CmuxNextDaemonService

/// The right sidebar's actions (inventory row 24): Toggle Right Sidebar, Focus
/// Right Sidebar and its section switches (Files, Find, Vault, Feed, Dock,
/// Cloud), on the active window. Each shows the sidebar at its section.
enum RightSidebarHandlers {
    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        registry.bind("toggleRightSidebar", run: { _ in
            try window(context).toggleRightSidebar()
        })
        registry.bind("focusRightSidebar", run: { invocation in
            let controller = try window(context)
            guard controller.showRightSidebar(focus: invocation.allowsViewChange) else { throw ActionFailure.needsAppCapability("right-sidebar") }
        })
        for mode in RightSidebarMode.allCases {
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
