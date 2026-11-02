public import CmuxNextActions

/// Vertical tabs' actions (`VerticalTabsActionCatalog`), in the tab bar's empty-area menu and the palette:
/// Turn On / Turn Off Vertical Tabs (the pane's workspace's own choice, ``WorkspaceVerticalTabs``), Use
/// Vertical Tabs for All Workspaces (`tabs.verticalTabs`), Collapse / Expand Tabs, and Auto-Expand Tabs
/// on Hover (`tabs.verticalTabsExpandOnHover`). Panes follow the store and the settings by observation.
@MainActor
public final class VerticalTabsActions {
    public static let toggle: ActionID = "tabs.verticalTabs.toggle"
    public static let allWorkspaces: ActionID = "tabs.verticalTabs.allWorkspaces"
    public static let collapse: ActionID = "tabs.verticalTabs.collapse"
    public static let expandOnHover: ActionID = "tabs.verticalTabs.expandOnHover"

    private let host: any VerticalTabsHost
    private let store: WorkspaceVerticalTabs

    /// `store` is the app's (`AppServices.workspaceVerticalTabs`); tests pass their own.
    public init(host: any VerticalTabsHost, store: WorkspaceVerticalTabs) {
        self.host = host
        self.store = store
    }

    public func bind(into registry: ActionRegistry) {
        let (host, store) = (host, store)
        let (toggle, allWorkspaces, collapse, expandOnHover) = (Self.toggle, Self.allWorkspaces, Self.collapse, Self.expandOnHover)
        let isVertical = { (pane: VerticalTabsPane) in
            pane.workspaceID.map { store.isVertical($0, allWorkspaces: host.design.verticalTabs) } ?? false
        }
        registry.bind(toggle, invoke: { invocation in
            guard let pane = host.verticalTabsPane(invocation), pane.takesVerticalTabs, let id = pane.workspaceID else { return }
            store.set(!isVertical(pane), for: id, allWorkspaces: host.design.verticalTabs)
        })
        ActionTargetTitles.set(toggle, in: registry) { invocation in
            host.verticalTabsPane(invocation).flatMap { isVertical($0) ? VerticalTabsStrings.turnOff : nil }
        }
        ActionTargetTitles.setPaletteTitle(toggle, in: registry) {
            host.focusedVerticalTabsPane.flatMap { isVertical($0) ? VerticalTabsStrings.turnOff : nil }
        }

        registry.bindEffect(allWorkspaces) { _ in
            let path = VerticalTabsSetting.configPath
            if let refusal = host.verticalTabsSettingRefusal(path) { return .refused(refusal) }
            let on = !host.design.verticalTabs
            // Every workspace shows the new choice, its own choice included (``WorkspaceVerticalTabs/clearChoices()``).
            store.clearChoices()
            host.design.verticalTabs = on
            host.writeVerticalTabsSetting("vertical tabs setting", path, on == VerticalTabsSetting.fallback ? nil : .bool(on))
            return .done
        }
        ActionTargetTitles.setState(allWorkspaces, in: registry) { _ in host.design.verticalTabs }
        ActionTargetTitles.setPaletteState(allWorkspaces, in: registry) { host.design.verticalTabs }

        registry.bind(collapse, invoke: { _ in store.setCollapsed(!store.isCollapsed) })
        ActionTargetTitles.set(collapse, in: registry) { _ in store.isCollapsed ? VerticalTabsStrings.expand : nil }
        ActionTargetTitles.setPaletteTitle(collapse, in: registry) { store.isCollapsed ? VerticalTabsStrings.expand : nil }

        registry.bindEffect(expandOnHover) { _ in
            let path = VerticalTabsSetting.expandOnHoverPath
            if let refusal = host.verticalTabsSettingRefusal(path) { return .refused(refusal) }
            let on = !host.design.verticalTabsExpandOnHover
            host.design.verticalTabsExpandOnHover = on
            host.writeVerticalTabsSetting("vertical tabs expand on hover setting", path, on == VerticalTabsSetting.expandOnHoverFallback ? nil : .bool(on))
            return .done
        }
        ActionTargetTitles.setState(expandOnHover, in: registry) { _ in host.design.verticalTabsExpandOnHover }
        ActionTargetTitles.setPaletteState(expandOnHover, in: registry) { host.design.verticalTabsExpandOnHover }

        // After the binds: `bind` registers a fresh action and drops an earlier hide rule.
        // An app pane and the Home Chief pane show no tab bar of either kind (PaneTabBarHandlers).
        for id in [toggle, allWorkspaces] {
            ActionTargetVisibility.hide(id, in: registry) { invocation in
                host.verticalTabsPane(invocation).map { !$0.takesVerticalTabs } ?? false
            }
        }
        // Collapse Tabs and Auto-Expand Tabs on Hover act on a vertical list: shown only while the
        // right-clicked bar is one.
        for id in [collapse, expandOnHover] {
            ActionTargetVisibility.hide(id, in: registry) { invocation in
                host.verticalTabsPane(invocation).map { !$0.takesVerticalTabs || !isVertical($0) } ?? true
            }
        }
    }
}

/// The vertical tabs rows' titles while they name the other change (SettingsActions.xcstrings in CmuxNextActions
/// holds the catalog titles).
private struct VerticalTabsStrings {
    static var turnOff: String { String(localized: "verticalTabs.turnOff", defaultValue: "Turn Off Vertical Tabs", bundle: .module) }
    static var expand: String { String(localized: "verticalTabs.expand", defaultValue: "Expand Tabs", bundle: .module) }
}
