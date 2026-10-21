import CmuxNextActions
import CmuxNextBridge
import CmuxNextLayout

/// Hide Tab Bar / Show Tab Bar and New Horizontal Tab (cx-soza): a pane's own
/// tab bar choice (``PaneTabBarChoices``, the only way a tab bar hides), and
/// a tab in the focused pane that turns its tab bar on first.
enum PaneTabBarHandlers {
    static let toggle: ActionID = "pane.toggleTabBar"
    static let newTab: ActionID = "newTab.horizontal"

    static func bind(into registry: ActionRegistry, context ctx: AppActionContext) {
        registry.bind(toggle, invoke: { invocation in
            guard let controller = ctx.paneController(invocation) else { return }
            if let reason = noTabBarReason(controller) { return ctx.refuse(reason) }
            controller.showTabBar(controller.view.hidesStrip)
        })
        // The row reads as the change it makes (cx-5425v): Hide Tab Bar while the pane shows it,
        // else the catalog's Show Tab Bar. The CLI keeps `pane toggle-tab-bar`.
        ActionTargetTitles.set(toggle, in: registry) { invocation in
            ctx.paneController(invocation).flatMap { $0.view.hidesStrip ? nil : PaneTabBarStrings.hide }
        }
        ActionTargetTitles.setPaletteTitle(toggle, in: registry) {
            ctx.services.windows.active?.focusedPane.flatMap { $0.view.hidesStrip ? nil : PaneTabBarStrings.hide }
        }
        registry.bind(newTab, invoke: { invocation in
            guard let controller = ctx.paneController(invocation) else { return }
            if let reason = noTabBarReason(controller) { return ctx.refuse(reason) }
            if controller.view.hidesStrip { controller.showTabBar(true) }
            TabLifecycle.newTabOfPaneKind(ctx, invocation, inStrip: true)
        })
        // An app workspace's one pane shows its app without a tab bar (`app-screens-v1`).
        // After both binds: `bind` registers a fresh action and drops an earlier hide rule.
        for id in [toggle, newTab] {
            // The Home Chief pane has no tab bar to show and takes no new tab (home-chief-pane.md).
            ActionTargetVisibility.hide(id, in: registry) { invocation in
                ctx.paneController(invocation).map { $0.isAppPane || $0.isPinnedDockPane } ?? false
            }
            // The palette, the CLI and MCP say why instead of reporting a run that did nothing.
            ctx.setTargetReason(id) { invocation in ctx.paneController(invocation).flatMap(noTabBarReason) }
        }
    }

    /// Why `controller` takes no tab bar change and no new tab, or nil.
    static func noTabBarReason(_ controller: PaneController) -> String? {
        if controller.isPinnedDockPane { return RefusalStrings.chiefPaneHasNoTabBar }
        if controller.isAppPane { return RefusalStrings.appPaneHasNoTabBar }
        return nil
    }
}

extension PaneController {
    /// An app workspace's pane: it never shows a tab bar.
    var isAppPane: Bool { daemon.store.workspace(containing: pane.handle)?.app != nil }

    /// A pane of a pinned dock that takes no other tab (the Home Chief pane, `pinned-dock-v1`):
    /// it shows no tab bar and never closes.
    var isPinnedDockPane: Bool {
        let column = daemon.store.workspace(containing: pane.handle)?.screens.lazy.flatMap(\.columns)
            .first { $0.layout.paneIDs.contains(self.pane.handle) }
        return column?.dock.map { !LayoutMapping.dock($0).takesTabs } ?? false
    }

    /// Shows or hides this pane's tab bar now. Shown is the default, so it is no choice.
    func showTabBar(_ shown: Bool) {
        services.paneTabBars.set(shown ? nil : false, for: paneKey)
        apply(snapshot())
    }
}

/// The toggle's title while the pane shows its tab bar (Handlers.xcstrings).
enum PaneTabBarStrings {
    static var hide: String { String(localized: "paneTabBar.hide", defaultValue: "Hide Tab Bar", table: "Handlers", bundle: .module) }
}
