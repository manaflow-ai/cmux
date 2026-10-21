import CmuxNextActions

/// Sidebar actions (category `sidebar`) beyond `toggleSidebar` (bound in
/// `AppActions`), the right sidebar (`RightSidebarHandlers`) and the session
/// vault (`VaultHandlers`): the file explorer's actions (`FileExplorerHandlers`,
/// on the active window's Files section). The checklist actions are
/// `WorkspaceChecklistHandlers`.
enum SidebarHandlers {
    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        let services = context.services
        FileExplorerHandlers.bind(into: registry, explorer: { [weak services] in services?.fileExplorers.activeExplorer },
                                  effects: services.fileExplorers.effects)
        // The right sidebar's Find section is the file explorer's search (a123).
        registry.bindUnavailable(["switchRightSidebarToFind"], ActionFailure.needsAppCapability("right-sidebar"))
    }
}
