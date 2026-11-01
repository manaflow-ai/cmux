import CmuxNextActions
import CmuxNextDesign
import CmuxNextSettings
import os

/// Sidebar Density: Compact / Comfortable / Expanded (cx-13w3; palette and
/// the sidebar's Options). Each writes `sidebar.density`, so the choice follows cmux.json;
/// the menu checks the current one and keeps every choice visible.
enum SidebarDensityActions {
    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "app.actions")

    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        let current = { (context.services.settings?.snapshot.sidebarSections ?? .defaults).density }
        let choices: [(ActionID, SidebarDensity)] = [
            ("sidebar.density.compact", .compact), ("sidebar.density.comfortable", .comfortable), ("sidebar.density.expanded", .expanded),
        ]
        for (id, value) in choices {
            registry.bind(id, unavailable: { nil }) { invocation in
                guard let settings = context.services.settings, current() != value else { return }
                let path = SidebarSectionsSetting.densityPath
                try AppearanceHandlers.requireUnmanaged(path, context)
                guard let descriptor = SettingsSchema.descriptor(for: path) else { return }
                let writer = SettingWriter(invocation.origin)
                Task {
                    do { try await settings.setSetting(descriptor, to: .string(value.rawValue), by: writer) } catch {
                        logger.error("sidebar.density failed: \(String(describing: error), privacy: .public)")
                    }
                }
            }
            ActionTargetTitles.setState(id, in: registry) { _ in current() == value }
        }
    }
}
