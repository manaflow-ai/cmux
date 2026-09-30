import CmuxNextActions
import CmuxNextBridge
import Foundation

/// "Show Tab Resource Usage" and "Show Workspace Resource Usage": open the
/// target's hover card (CPU and memory, sampled once per second while it
/// is shown) without the pointer, until the next key press, click or
/// scroll. The numbers themselves are the `resources` control method.
enum ResourceHandlers {
    static func bind(into registry: ActionRegistry, context ctx: AppActionContext) {
        registry.bind("tab.showResources", run: { invocation in
            guard let (pane, id) = ctx.tab(invocation) else { return }
            guard pane.view.stripView.showHoverCard(for: id) else {
                throw ActionFailure.invalidTarget(RefusalStrings.resourceCardNotShown)
            }
        })
        registry.bind("workspace.showResources", run: { invocation in
            let (workspace, _) = try ctx.workspace(invocation)
            // Each window's sidebar lists only its own workspaces.
            let manager = ctx.services.windows!
            let lists = { (window: WindowController) in manager.registry.members(of: window.state.id).contains(workspace.id) }
            let window = manager.active.flatMap { lists($0) ? $0 : nil } ?? manager.controllers.first(where: lists)
            guard let window, window.sidebar.container.sidebarView.showHoverCard(for: SidebarWorkspaceID(workspace.id)) else {
                throw ActionFailure.invalidTarget(RefusalStrings.resourceCardNotShown)
            }
        })
    }
}
