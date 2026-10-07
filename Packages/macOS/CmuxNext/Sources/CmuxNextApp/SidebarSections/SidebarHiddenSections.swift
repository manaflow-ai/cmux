import CmuxNextActions
import CmuxNextSettings
import CmuxNextSidebar
import os

/// Projects and Recents hide from their headers' menus and come back from the
/// sidebar's menu or Settings (`sidebar.showProjects`, `sidebar.showRecents`;
/// Leo 2026-10-06). Each is a setting, so the choice follows cmux.json.
enum SidebarHiddenSections {
    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "app.actions")

    /// The rows a section header's menu leaves out: Hide on an app section
    /// only, Hide Section on Recents only (other sections are removed
    /// instead). Recents shows Hide Section alone, not its app's Hide too.
    static func headerMenuRemovals(_ id: LayoutSectionID, isApp: Bool) -> Set<ActionID> {
        let isRecents = id == SidebarLayoutDocument.recentsSectionID
        var removed: Set<ActionID> = []
        if !isApp || isRecents { removed.insert("sidebar.item.hideApp") }
        if !isRecents { removed.insert("sidebar.section.hide") }
        return removed
    }

    /// Hide Section on `target` hides Recents: the Recents header, or the
    /// palette with no target. Read by id, so it works while the daemon
    /// has no sidebar layout (the sidebar draws the defaults then).
    static func hidesRecents(_ target: ActionTargetRef?) -> Bool {
        guard let target else { return true }
        return target.id == SidebarLayoutDocument.recentsSectionID.rawValue
    }

    /// The setting Hide Section turns off.
    static let hidePath = SidebarSectionsSetting.showRecentsPath
    /// The settings Show Hidden Sections turns back on.
    static let showHiddenPaths = [SidebarSectionsSetting.showProjectsPath, SidebarSectionsSetting.showRecentsPath]

    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        let settings = { context.services.settings?.snapshot.sidebarSections ?? .defaults }
        registry.bind("sidebar.section.hide", unavailable: { settings().showRecents ? nil : SidebarSectionStrings.alreadyHidden }) { invocation in
            guard hidesRecents(invocation.target) else { throw ActionFailure(message: SidebarSectionStrings.notHideable) }
            try write([(SidebarSectionsSetting.showRecentsPath, false)], invocation, context)
        }
        registry.bind("sidebar.projects.hide", unavailable: { settings().showProjects ? nil : SidebarSectionStrings.alreadyHidden }) { invocation in
            try write([(SidebarSectionsSetting.showProjectsPath, false)], invocation, context)
        }
        registry.bind("sidebar.sections.showHidden", unavailable: {
            settings().showProjects && settings().showRecents ? SidebarSectionStrings.noneHidden : nil
        }) { invocation in
            try write([(SidebarSectionsSetting.showProjectsPath, true), (SidebarSectionsSetting.showRecentsPath, true)], invocation, context)
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
