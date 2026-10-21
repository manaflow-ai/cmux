import CmuxNextActions

/// Sidebar actions (category `sidebar`) beyond `toggleSidebar` (bound in
/// `AppActions`), the right sidebar (`RightSidebarHandlers`) and the session
/// vault (`VaultHandlers`): the file explorer's actions (`FileExplorerHandlers`,
/// on the active window's Files section) and Open Find as Pane. The checklist
/// actions are `WorkspaceChecklistHandlers`.
enum SidebarHandlers {
    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        let services = context.services
        FileExplorerHandlers.bind(into: registry, explorer: { [weak services] in services?.fileExplorers.runTarget(for: $0) },
                                  effects: services.fileExplorers.effects)
        // Open Find as Pane: the Find section in a tab, on the focused terminal's folder
        // (or the CLI's `--pane` or `--path`).
        let findPanes = services.fileExplorers.findPanes
        services.pages.register(findPanes) // at launch, so a restored tab finds it
        registry.bind("palette.openFindPane", run: { invocation in
            guard let folder = context.openAsPaneFolder(invocation) else { return }
            try findPanes.open(folder: folder, focus: invocation.allowsViewChange)
        })
    }
}
