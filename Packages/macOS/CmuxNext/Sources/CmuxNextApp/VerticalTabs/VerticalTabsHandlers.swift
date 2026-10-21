import AppKit
import CmuxNextActions
import CmuxNextSettings

/// Vertical tabs' actions (`VerticalTabsActionCatalog`), in the tab bar's empty-area menu and the palette:
/// Turn On / Turn Off Vertical Tabs (the pane's workspace's own choice, ``WorkspaceVerticalTabs``), Use
/// Vertical Tabs for All Workspaces (`tabs.verticalTabs`), Collapse / Expand Tabs, and Auto-Expand Tabs
/// on Hover (`tabs.verticalTabsExpandOnHover`). Panes follow the store and the settings by observation.
enum VerticalTabsHandlers {
    static let toggle: ActionID = "tabs.verticalTabs.toggle"
    static let allWorkspaces: ActionID = "tabs.verticalTabs.allWorkspaces"
    static let collapse: ActionID = "tabs.verticalTabs.collapse"
    static let expandOnHover: ActionID = "tabs.verticalTabs.expandOnHover"

    /// `store` is the app's (`WorkspaceVerticalTabs.shared`); tests pass their own.
    static func bind(into registry: ActionRegistry, context ctx: AppActionContext, store: WorkspaceVerticalTabs = .shared) {
        let isVertical = { (controller: PaneController) in
            workspaceID(of: controller).map { store.isVertical($0, allWorkspaces: ctx.design.verticalTabs) } ?? false
        }
        registry.bind(toggle, invoke: { invocation in
            guard let controller = ctx.paneController(invocation), takesVerticalTabs(controller), let id = workspaceID(of: controller) else { return }
            store.set(!isVertical(controller), for: id, allWorkspaces: ctx.design.verticalTabs)
        })
        ActionTargetTitles.set(toggle, in: registry) { invocation in
            ctx.paneController(invocation).flatMap { isVertical($0) ? VerticalTabsStrings.turnOff : nil }
        }
        ActionTargetTitles.setPaletteTitle(toggle, in: registry) {
            ctx.services.windows.active?.focusedPane.flatMap { isVertical($0) ? VerticalTabsStrings.turnOff : nil }
        }

        registry.bind(allWorkspaces, run: { _ in
            let path = VerticalTabsSetting.configPath
            try AppearanceHandlers.requireUnmanaged(path, ctx)
            let on = !ctx.design.verticalTabs
            // Every workspace shows the new choice, its own choice included (``WorkspaceVerticalTabs/clearChoices``).
            store.clearChoices()
            ctx.design.verticalTabs = on
            ctx.writeSetting("vertical tabs setting", path, on == VerticalTabsSetting.fallback ? nil : .bool(on), reloadOnFailure: true)
        })
        ActionTargetTitles.setState(allWorkspaces, in: registry) { _ in ctx.design.verticalTabs }
        ActionTargetTitles.setPaletteState(allWorkspaces, in: registry) { ctx.design.verticalTabs }

        registry.bind(collapse, invoke: { _ in store.setCollapsed(!store.isCollapsed) })
        ActionTargetTitles.set(collapse, in: registry) { _ in store.isCollapsed ? VerticalTabsStrings.expand : nil }
        ActionTargetTitles.setPaletteTitle(collapse, in: registry) { store.isCollapsed ? VerticalTabsStrings.expand : nil }

        registry.bind(expandOnHover, run: { _ in
            let path = VerticalTabsSetting.expandOnHoverPath
            try AppearanceHandlers.requireUnmanaged(path, ctx)
            let on = !ctx.design.verticalTabsExpandOnHover
            ctx.design.verticalTabsExpandOnHover = on
            ctx.writeSetting("vertical tabs expand on hover setting", path, on == VerticalTabsSetting.expandOnHoverFallback ? nil : .bool(on),
                             reloadOnFailure: true)
        })
        ActionTargetTitles.setState(expandOnHover, in: registry) { _ in ctx.design.verticalTabsExpandOnHover }
        ActionTargetTitles.setPaletteState(expandOnHover, in: registry) { ctx.design.verticalTabsExpandOnHover }

        // After the binds: `bind` registers a fresh action and drops an earlier hide rule.
        // An app pane and the Home Chief pane show no tab bar of either kind (PaneTabBarHandlers).
        for id in [toggle, allWorkspaces] {
            ActionTargetVisibility.hide(id, in: registry) { invocation in
                ctx.paneController(invocation).map { !takesVerticalTabs($0) } ?? false
            }
        }
        // Collapse Tabs and Auto-Expand Tabs on Hover act on a vertical list: shown only while the
        // right-clicked bar is one.
        for id in [collapse, expandOnHover] {
            ActionTargetVisibility.hide(id, in: registry) { invocation in
                ctx.paneController(invocation).map { !takesVerticalTabs($0) || !isVertical($0) } ?? true
            }
        }
    }

    /// The workspace whose choice a pane's tab bar follows.
    static func workspaceID(of controller: PaneController) -> String? {
        controller.workspace?.workspace.id ?? controller.daemon.store.workspace(containing: controller.pane.handle)?.id
    }

    /// A pane that can show a vertical list at all: not an app's pane, not a pinned dock's (the pane's
    /// snapshot shows no list there, so its menu offers no vertical tabs rows either).
    private static func takesVerticalTabs(_ controller: PaneController) -> Bool {
        guard !controller.isAppPane else { return false }
        let column = controller.daemon.store.workspace(containing: controller.pane.handle)?.screens.lazy.flatMap(\.columns)
            .first { $0.layout.paneIDs.contains(controller.pane.handle) }
        return column?.dock?.isPinned != true
    }
}

/// The vertical tabs rows' titles while they name the other change (SettingsActions.xcstrings in CmuxNextActions
/// holds the catalog titles; these live in Handlers.xcstrings).
enum VerticalTabsStrings {
    static var turnOff: String { String(localized: "verticalTabs.turnOff", defaultValue: "Turn Off Vertical Tabs", table: "Handlers", bundle: .module) }
    static var expand: String { String(localized: "verticalTabs.expand", defaultValue: "Expand Tabs", table: "Handlers", bundle: .module) }
}

/// The tab bar's empty-area menu (Edge's and Chrome's vertical-tab menus): New Tab, Reopen Closed Tab,
/// Bookmark All Tabs, Move All Tabs to a New Workspace; the vertical tabs rows; Task Manager.
enum TabStripMenu {
    /// The tab bar's empty-area menu (`ActionMenuContext.tabStrip`; the strip's or the vertical list's), then
    /// More: the kinds of new tab (New) and the pane's menu with its own More inlined, titled as the pane's
    /// menu titles them, so nothing the strip's empty area offered before is lost.
    static func make(target: ActionTargetRef, registry: ActionRegistry) -> NSMenu {
        let catalog = ContextMenuCatalog.shared
        let menu = registry.makeContextMenu(for: .tabStrip, target: target)
        let pane = catalog.entries(for: .pane).flatMap { entry -> [ContextMenuEntry] in
            guard case .folder(.more, let children) = entry else { return [entry] }
            return [.separator] + children + [.separator]
        }
        let more = registry.makeContextMenu(for: .pane, target: target, entries: [.folder(.new, catalog.entries(for: .newTab)), .separator] + pane)
        guard !more.items.isEmpty else { return menu }
        let item = NSMenuItem(title: MenuFolder.more.title, action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: MenuFolder.more.symbol, accessibilityDescription: nil)
        item.image?.isTemplate = true
        more.title = item.title
        item.submenu = more
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        menu.addItem(item)
        return menu
    }
}
