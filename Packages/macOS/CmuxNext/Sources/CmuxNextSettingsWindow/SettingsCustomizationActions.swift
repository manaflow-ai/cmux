public import CmuxNextActions

/// Settings navigation shared by the palette and sidebar context menu.
@MainActor public struct SettingsCustomizationActions {
    public init() {}
    public func bind(into registry: ActionRegistry,
                            effect: @escaping @MainActor (String, Bool) throws -> ActionEffect) {
        // Showing Settings is local and immediate; both effects finish on this turn.
        registry.bindEffect("sidebar.customize", requires: nil, effect: { invocation in
            return try effect(SettingsDeepLink.sidebarRoute(), invocation.allowsViewChange)
        })
        registry.bindEffect("settings.customizeMenus", requires: nil, effect: { invocation in
            return try effect("#/settings/menus", invocation.allowsViewChange)
        })
    }
}
