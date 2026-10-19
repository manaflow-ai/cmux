import CmuxNextActions
import CmuxNextDesign
import CmuxNextSettings
import os

/// Group ▸ Group by None / Group by Folder in the sidebar's menu (Leo
/// 2026-10-06). Each writes `sidebar.groupBy`, so the choice follows cmux.json;
/// the current one is unavailable.
enum SidebarGroupByActions {
    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "app.actions")

    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        let current = { context.services.settings?.snapshot.sidebarSections.groupBy ?? .none }
        let choices: [(ActionID, SidebarGroupBy)] = [("sidebar.groupBy.none", .none), ("sidebar.groupBy.folder", .folder)]
        for (id, value) in choices {
            registry.bind(id, unavailable: { current() == value ? SidebarSectionStrings.alreadyGrouped : nil }) { invocation in
                try write(SidebarSectionsSetting.groupByPath, .string(value.rawValue), invocation, context)
            }
        }
        // The session tree's Keep Rows in Place / Move Sessions That Need You: this window's own choice.
        for (id, order) in [("sidebar.rowOrder.stable", SidebarRowOrder.stable), ("sidebar.rowOrder.attention", .attention)] as [(ActionID, SidebarRowOrder)] {
            registry.bind(id, run: { invocation in let sidebar = try context.window(invocation).sidebar; sidebar.model.rowOrder = order; sidebar.rows.show() })
            ActionTargetVisibility.hide(id, in: registry) { invocation in
                !(context.services.settings?.snapshot.sidebarSections.sessionTree ?? false) || (try? context.window(invocation))?.sidebar.model.resolvedRowOrder == order
            }
        }
    }

    /// Writes one sidebar setting through the settings schema (a managed key refuses); Density's too.
    static func write(_ path: [String], _ value: CmuxNextSettings.JSONValue, _ invocation: ActionInvocation, _ context: AppActionContext) throws {
        guard let settings = context.services.settings else { return }
        try AppearanceHandlers.requireUnmanaged(path, context)
        guard let descriptor = SettingsSchema.descriptor(for: path) else { return }
        let writer = SettingWriter(invocation.origin)
        Task {
            do { try await settings.setSetting(descriptor, to: value, by: writer) } catch {
                logger.error("\(path.joined(separator: "."), privacy: .public) failed: \(String(describing: error), privacy: .public)")
            }
        }
    }
}
