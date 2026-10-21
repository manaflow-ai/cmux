import CmuxNextActions
import CmuxNextSettings

/// Minimal mode (cx-w1r5; Lawrence 2026-10-09: "some people like minimal mode"):
/// Enable Minimal Mode and Disable Minimal Mode (palette, CLI
/// `sidebar enable-minimal-mode` / `disable-minimal-mode`, and the sidebar's
/// menu, which shows only the one that applies) set `sidebar.minimal`, the
/// Settings row Minimal Mode (not `sidebar.minimalMode`, the older Hide Bands
/// Until Hover row), so the choice follows cmux.json. The config
/// layer is the one owner; the sidebar only reads the setting.
enum SidebarMinimalToggle {
    static let path = SidebarSectionsSetting.minimalPath

    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        let minimal = { (context.services.settings?.snapshot.sidebarSections ?? .defaults).minimal }
        for (id, value) in [("palette.enableMinimalMode", true), ("palette.disableMinimalMode", false)] as [(ActionID, Bool)] {
            registry.bind(id, unavailable: { nil }) { _ in
                guard minimal() != value else { return }
                try AppearanceHandlers.requireUnmanaged(path, context)
                context.writeSetting("sidebar minimal setting", path, .bool(value))
            }
            // The menu offers Enable while off and Disable while on.
            ActionTargetVisibility.hide(id, in: registry) { _ in minimal() == value }
        }
    }
}
