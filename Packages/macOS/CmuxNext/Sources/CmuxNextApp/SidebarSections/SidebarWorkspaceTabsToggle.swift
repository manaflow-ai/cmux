import CmuxNextActions
import CmuxNextSettings
import os

/// Show Tabs Under Workspaces (Leo 2026-10-09): the sidebar's and a workspace
/// row's menus check it while each workspace lists its tabs beneath it. It
/// toggles `sidebar.showWorkspaceTabs`, the Settings row Show Workspace Tabs,
/// so the choice follows cmux.json.
enum SidebarWorkspaceTabsToggle {
    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "app.actions")

    static let id: ActionID = "sidebar.workspaceTabs.toggle"
    static let path = SidebarSectionsSetting.showWorkspaceTabsPath

    static func next(showing: Bool) -> Bool { !showing }

    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        let showing = { (context.services.settings?.snapshot.sidebarSections ?? .defaults).showWorkspaceTabs }
        registry.bind(id, unavailable: { nil }) { invocation in
            guard let settings = context.services.settings else { return }
            try AppearanceHandlers.requireUnmanaged(path, context)
            let value = next(showing: showing())
            let writer = SettingWriter(invocation.origin)
            Task {
                guard let descriptor = SettingsSchema.descriptor(for: path) else { return }
                do { try await settings.setSetting(descriptor, to: .bool(value), by: writer) } catch {
                    logger.error("sidebar workspace tabs setting failed: \(String(describing: error), privacy: .public)")
                }
            }
        }
        ActionTargetTitles.setState(id, in: registry) { _ in showing() }
    }
}
