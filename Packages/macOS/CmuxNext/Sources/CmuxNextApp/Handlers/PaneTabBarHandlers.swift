import CmuxNextActions

/// Hide Tab Bar / Show Tab Bar and New Horizontal Tab (cx-soza): a pane's own
/// tab bar choice (``PaneTabBarChoices``, the only way a tab bar hides), and
/// a tab in the focused pane that turns its tab bar on first.
enum PaneTabBarHandlers {
    static let toggle: ActionID = "pane.toggleTabBar"
    static let newTab: ActionID = "newTab.horizontal"

    static func bind(into registry: ActionRegistry, context ctx: AppActionContext) {
        registry.bind(toggle, invoke: { invocation in
            guard let controller = ctx.paneController(invocation), !controller.isAppPane else { return }
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
