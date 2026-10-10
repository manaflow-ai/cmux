import CmuxNextActions
import CmuxNextSettings
import CmuxNextSidebar
import os

/// Projects hides from its header's menu and comes back from the sidebar's
/// menu or Settings (`sidebar.showProjects`; Leo 2026-10-06). It is a
/// setting, so the choice follows cmux.json. All chats is not a sidebar
/// section any more (cx-n0i9: it is on the New Tab page), so Hide Section
/// hides nothing and `sidebar.showChats` no longer changes the sidebar.
enum SidebarHiddenSections {
    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "app.actions")

    /// The rows a section header's menu leaves out: Hide on an app section
    /// only, and Hide Section everywhere (no sidebar section hides that way now).
    static func headerMenuRemovals(_ id: LayoutSectionID, isApp: Bool) -> Set<ActionID> {
        var removed: Set<ActionID> = ["sidebar.section.hide"]
        if !isApp { removed.insert("sidebar.item.hideApp") }
        return removed
    }

    /// The settings Show Hidden Sections turns back on: Projects.
    static let showHiddenPaths = [SidebarSectionsSetting.showProjectsPath]

    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        let settings = { context.services.settings?.snapshot.sidebarSections ?? .defaults }
        registry.bind("sidebar.section.hide", unavailable: { SidebarSectionStrings.notHideable }) { _ in
            throw ActionFailure(message: SidebarSectionStrings.notHideable)
        }
        registry.bind("sidebar.projects.hide", unavailable: { settings().showProjects ? nil : SidebarSectionStrings.alreadyHidden }) { invocation in
            try write([(SidebarSectionsSetting.showProjectsPath, false)], invocation, context)
        }
        registry.bind("sidebar.sections.showHidden", unavailable: {
            settings().showProjects ? SidebarSectionStrings.noneHidden : nil
        }) { invocation in
            try write(showHiddenPaths.map { ($0, true) }, invocation, context)
        }
    }

    /// Writes each toggle through the settings schema (managed keys refuse).
    private static func write(_ values: [([String], Bool)], _ invocation: ActionInvocation, _ context: AppActionContext) throws {
        guard let settings = context.services.settings else { return }
        for (path, _) in values { try AppearanceHandlers.requireUnmanaged(path, context) }
        let writer = SettingWriter(invocation.origin)
        Task {
            for (path, value) in values {
                guard let descriptor = SettingsSchema.descriptor(for: path) else { continue }
                do { try await settings.setSetting(descriptor, to: .bool(value), by: writer) } catch {
                    logger.error("sidebar section setting \(path.joined(separator: "."), privacy: .public) failed: \(String(describing: error), privacy: .public)")
                }
            }
        }
    }
}
