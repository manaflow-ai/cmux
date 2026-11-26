public import CmuxNextActions

/// Settings navigation shared by the palette and sidebar context menu.
@MainActor public struct SettingsCustomizationActions {
    public init() {}
    public func bind(into registry: ActionRegistry,
                     effect: @escaping @MainActor (String, Bool) throws -> ActionEffect,
                     refuse: @escaping @MainActor (any Error) -> Void) {
        // The package API is nonthrowing. The app owns its existing error-to-refusal policy.
        registry.bindEffect("sidebar.customize", effect: { invocation in
            do { return try effect(SettingsDeepLink.sidebarRoute(), invocation.allowsViewChange) }
            catch { refuse(error); return .done }
        })
        registry.bindEffect("settings.customizeMenus", effect: { invocation in
            do { return try effect("#/settings/menus", invocation.allowsViewChange) }
            catch { refuse(error); return .done }
        })
    }
}
