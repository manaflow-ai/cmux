import CmuxNextActions

/// Show Tab Bar and New Horizontal Tab (cx-soza): a pane's own tab bar
/// choice (``PaneTabBar``), and a tab in the focused pane that turns its tab
/// bar on first. Cmd-T then adds tabs there instead of opening a workspace.
enum PaneTabBarHandlers {
    static let toggle: ActionID = "pane.toggleTabBar"
    static let newTab: ActionID = "newTab.horizontal"

    static func bind(into registry: ActionRegistry, context ctx: AppActionContext) {
        registry.bind(toggle, invoke: { invocation in
            guard let controller = ctx.paneController(invocation) else { return }
            controller.showTabBar(controller.view.hidesStrip)
        })
        ActionTargetTitles.setState(toggle, in: registry) { invocation in
            ctx.paneController(invocation).map { !$0.view.hidesStrip }
        }
        registry.bind(newTab, invoke: { invocation in
            guard let controller = ctx.paneController(invocation) else { return }
            if controller.view.hidesStrip { controller.showTabBar(true) }
            TabLifecycle.newTabOfPaneKind(ctx, invocation, inStrip: true)
        })
    }
}

extension PaneController {
    /// Shows or hides this pane's tab bar now. A choice equal to the kind's
    /// default is no choice, so the pane follows `tabs.tabBar` again.
    func showTabBar(_ shown: Bool) {
        let mode = (services.settings?.snapshot.paneTabBars ?? .init())[tabBarKind]
        let hiddenByDefault = PaneTabBar.hides(choice: nil, mode: mode) {
            ChatDockChrome.hidesStrip(self, tabCount: stripModel.tabs.count)
        }
        services.paneTabBars.set(shown == hiddenByDefault ? shown : nil, for: paneKey)
        apply(snapshot())
    }
}
