import CmuxNextActions

/// Sidebar actions (category `sidebar`) beyond `toggleSidebar` (bound in
/// `AppActions`), the right sidebar (`RightSidebarHandlers`) and the session
/// vault (`VaultHandlers`): the file explorer's actions (`FileExplorerHandlers`,
/// on the active window's Files section) and Open Find as Pane. The checklist
/// actions are `WorkspaceChecklistHandlers`.
enum SidebarHandlers {
    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        let services = context.services
        FileExplorerHandlers.bind(into: registry, explorer: { [weak services] in services?.fileExplorers.activeExplorer },
                                  effects: services.fileExplorers.effects)
        // Open Find as Pane: the Find section in a tab, on the focused terminal's folder.
        let findPanes = services.fileExplorers.findPanes
        services.pages.register(findPanes) // at launch, so a restored tab finds it
        registry.bind("palette.openFindPane", run: { invocation in
            let folder = services.windows.active.flatMap { services.fileExplorers.folder(focusedIn: $0) }
            try findPanes.open(folder: folder, focus: invocation.allowsViewChange)
        })
    }
}
