import CmuxNextActions
import CmuxNextSettings

/// Show Hover Cards (Leo 2026-10-21: the workspace hover card "needs ... a way to toggle it
/// off"): the sidebar's menu and a workspace row's menu check it while hover cards open on
/// hover. It toggles `sidebar.hoverCards.enabled`, the Settings row Show Hover Cards
/// (Appearance > Sidebar), so the choice follows cmux.json. The settings applier copies it
/// into `DesignSettings.hoverCardsEnabled`, whose change closes a card that is open.
enum SidebarHoverCardsToggle {
    static let id: ActionID = "sidebar.hoverCards.toggle"
    static let path = HoverCardSettings.enabledPath

    static func next(showing: Bool) -> Bool { !showing }

    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        let showing = { (context.services.settings?.snapshot.hoverCards ?? HoverCardSettings()).enabled }
        registry.bind(id, unavailable: { nil }) { _ in
            try AppearanceHandlers.requireUnmanaged(path, context)
            context.writeSetting("sidebar hover cards setting", path, .bool(next(showing: showing())))
        }
        ActionTargetTitles.setState(id, in: registry) { _ in showing() }
        ActionTargetTitles.setPaletteState(id, in: registry) { showing() }
    }
}
