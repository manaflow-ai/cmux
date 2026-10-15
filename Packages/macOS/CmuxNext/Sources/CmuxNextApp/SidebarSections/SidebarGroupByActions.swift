import CmuxNextActions
import CmuxNextDesign
import CmuxNextSettings
import os

/// Group ▸ Group by None / Group by Folder / Group by Status in the sidebar's
/// menu (Leo 2026-10-06; Status behind `labs.sidebarStatusGrouping`). Each
/// writes `sidebar.groupBy`, so the choice follows cmux.json; the current one
/// is unavailable.
enum SidebarGroupByActions {
    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "app.actions")

    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        let current = { context.services.settings?.snapshot.sidebarSections.groupBy ?? .none }
        // Group by Status is a Labs look: until `labs.sidebarStatusGrouping` is on it says so
        // instead of saving a value the sidebar reads as no grouping.
        let labsOff = { context.services.settings?.snapshot.lab(.sidebarStatusGrouping) != true }
        let choices: [(ActionID, SidebarGroupBy)] = [("sidebar.groupBy.none", .none), ("sidebar.groupBy.folder", .folder),
                                                    ("sidebar.groupBy.status", .status)]
        for (id, value) in choices {
            registry.bind(id, unavailable: {
                if value == .status, labsOff() { return SidebarSectionStrings.statusGroupingOff }
                return current() == value ? SidebarSectionStrings.alreadyGrouped : nil
            }) { invocation in
                try write(value, invocation, context)
            }
        }
    }

    /// Writes through the settings schema (a managed key refuses).
    private static func write(_ value: SidebarGroupBy, _ invocation: ActionInvocation, _ context: AppActionContext) throws {
        guard let settings = context.services.settings else { return }
        let path = SidebarSectionsSetting.groupByPath
        try AppearanceHandlers.requireUnmanaged(path, context)
        guard let descriptor = SettingsSchema.descriptor(for: path) else { return }
        let writer = SettingWriter(invocation.origin)
        Task {
            do { try await settings.setSetting(descriptor, to: .string(value.rawValue), by: writer) } catch {
                logger.error("sidebar.groupBy failed: \(String(describing: error), privacy: .public)")
            }
        }
    }
}
