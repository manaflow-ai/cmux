import CmuxNextActions
import CmuxNextSettings

/// Show Tabs Under Workspaces (Leo 2026-10-09): the sidebar's and a workspace
/// row's menus check it while each workspace lists its tabs beneath it. It
/// toggles `sidebar.showWorkspaceTabs`, the Settings row Show Workspace Tabs,
/// so the choice follows cmux.json.
enum SidebarWorkspaceTabsToggle {
    static let id: ActionID = "sidebar.workspaceTabs.toggle"
    static let path = SidebarSectionsSetting.showWorkspaceTabsPath

    static func next(showing: Bool) -> Bool { !showing }

    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        let showing = { (context.services.settings?.snapshot.sidebarSections ?? .defaults).showWorkspaceTabs }
        registry.bind(id, unavailable: { nil }) { _ in
            try AppearanceHandlers.requireUnmanaged(path, context)
            context.writeSetting("sidebar workspace tabs setting", path, .bool(next(showing: showing())))
        }
        ActionTargetTitles.setState(id, in: registry) { _ in showing() }
        // Minimal mode lists no tab rows (cx-w1r5), so the menus leave the row out.
        ActionTargetVisibility.hide(id, in: registry) { _ in (context.services.settings?.snapshot.sidebarSections ?? .defaults).minimal }
    }
}
