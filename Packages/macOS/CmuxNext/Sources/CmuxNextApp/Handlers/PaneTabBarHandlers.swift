import CmuxNextActions

/// Show Tab Bar and New Horizontal Tab (cx-soza): a pane's own tab bar
/// choice (``PaneTabBar``), and a tab in the focused pane that turns its tab
/// bar on first. Cmd-T then adds tabs there instead of opening a workspace.
enum PaneTabBarHandlers {
    static let toggle: ActionID = "pane.toggleTabBar"
    static let newTab: ActionID = "newTab.horizontal"

    static func bind(into registry: ActionRegistry, context ctx: AppActionContext) {
        registry.bind(toggle, invoke: { invocation in
            guard let controller = ctx.paneController(invocation), !controller.isAppPane else { return }
            controller.showTabBar(controller.view.hidesStrip)
        })
        ActionTargetTitles.setState(toggle, in: registry) { invocation in
            ctx.paneController(invocation).map { !$0.view.hidesStrip }
        }
        // The palette row is checked while the focused pane shows its tab bar: running it hides the bar.
        ActionTargetTitles.setPaletteState(toggle, in: registry) {
            ctx.services.windows.active?.focusedPane.map { !$0.view.hidesStrip } ?? false
        }
        // An app workspace's one pane shows its app without a tab bar (`app-screens-v1`).
        for id in [toggle, newTab] {
            ActionTargetVisibility.hide(id, in: registry) { invocation in ctx.paneController(invocation)?.isAppPane ?? false }
        }
        registry.bind(newTab, invoke: { invocation in
            guard let controller = ctx.paneController(invocation), !controller.isAppPane else { return }
            if controller.view.hidesStrip { controller.showTabBar(true) }
            TabLifecycle.newTabOfPaneKind(ctx, invocation, inStrip: true)
        })
    }
}

extension PaneController {
    /// An app workspace's pane: it never shows a tab bar.
    var isAppPane: Bool { daemon.store.workspace(containing: pane.handle)?.app != nil }

    /// Shows or hides this pane's tab bar now. A choice equal to the kind's
    /// default is no choice, so the pane follows `tabs.tabBar` again.
    func showTabBar(_ shown: Bool) {
        let mode = (services.settings?.snapshot.paneTabBars ?? .init())[tabBarKind]
        let hiddenByDefault = PaneTabBar.hides(choice: nil, mode: mode)
        services.paneTabBars.set(shown == hiddenByDefault ? shown : nil, for: paneKey)
        apply(snapshot())
    }
}
