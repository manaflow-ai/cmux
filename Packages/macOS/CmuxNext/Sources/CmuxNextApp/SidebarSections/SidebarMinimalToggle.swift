import CmuxNextActions
import CmuxNextSettings
import os

/// Minimal mode (cx-w1r5; Lawrence 2026-10-09: "some people like minimal mode"):
/// Enable Minimal Mode and Disable Minimal Mode (palette, CLI
/// `sidebar enable-minimal-mode` / `disable-minimal-mode`, and the sidebar's
/// menu, which shows only the one that applies) set `sidebar.minimal`, the
/// Settings row Minimal Sidebar, so the choice follows cmux.json. The config
/// layer is the one owner; the sidebar only reads the setting.
enum SidebarMinimalToggle {
    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "app.actions")
    static let path = SidebarSectionsSetting.minimalPath

    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        let minimal = { (context.services.settings?.snapshot.sidebarSections ?? .defaults).minimal }
        for (id, value) in [("palette.enableMinimalMode", true), ("palette.disableMinimalMode", false)] as [(ActionID, Bool)] {
            registry.bind(id, unavailable: { nil }) { invocation in
                guard let settings = context.services.settings, minimal() != value else { return }
                try AppearanceHandlers.requireUnmanaged(path, context)
                let writer = SettingWriter(invocation.origin)
                Task {
                    guard let descriptor = SettingsSchema.descriptor(for: path) else { return }
                    do { try await settings.setSetting(descriptor, to: .bool(value), by: writer) } catch {
                        logger.error("sidebar minimal setting failed: \(String(describing: error), privacy: .public)")
                    }
                }
            }
            // The menu offers Enable while off and Disable while on.
            ActionTargetVisibility.hide(id, in: registry) { _ in minimal() == value }
        }
    }
}
