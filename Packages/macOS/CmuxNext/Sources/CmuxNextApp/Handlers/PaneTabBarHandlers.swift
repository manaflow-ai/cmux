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
            if let reason = noToggleReason(controller) { return ctx.refuse(reason) }
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
        // The Home Chief pane takes no new tab, and has no tab bar to show or hide while it holds
        // only Home (home-chief-pane.md H1).
        for id in [toggle, newTab] {
            let isToggle = id == toggle
            ActionTargetVisibility.hide(id, in: registry) { invocation in
                ctx.paneController(invocation).map { (isToggle ? noToggleReason($0) : noTabBarReason($0)) != nil } ?? false
            }
            // The palette, the CLI and MCP say why instead of reporting a run that did nothing.
            ctx.setTargetReason(id) { invocation in
                ctx.paneController(invocation).flatMap { isToggle ? noToggleReason($0) : noTabBarReason($0) }
            }
        }
    }

    /// Why `controller` takes no new tab, or nil.
    static func noTabBarReason(_ controller: PaneController) -> String? {
        if controller.isPinnedDockPane { return RefusalStrings.chiefPaneHasNoTabBar }
        return noToggleReason(controller)
    }

    /// Why `controller`'s tab bar cannot be shown or hidden, or nil: an app's pane has none, and
    /// neither has the Home Chief pane while it holds only Home.
    static func noToggleReason(_ controller: PaneController) -> String? {
        if controller.isAppPane { return RefusalStrings.appPaneHasNoTabBar }
        return controller.pinnedDockHidesTabBar ? RefusalStrings.chiefPaneHasNoTabBar : nil
    }
}

extension PaneController {
    /// An app workspace's pane: it never shows a tab bar.
    var isAppPane: Bool { daemon.store.workspace(containing: pane.handle)?.app != nil }

    /// A pane of a pinned dock (the Home Chief pane, `pinned-dock-v1`): it takes no new tab (what Home
    /// opens goes beside it) and never closes; it shows no tab bar while it holds only Home.
    var isPinnedDockPane: Bool { pinnedDock != nil }

    /// A pinned dock's pane that holds only its pinned tab: no tab bar (``DockColumn/hidesTabBar(shownTabs:)``).
    var pinnedDockHidesTabBar: Bool { pinnedDock?.hidesTabBar(shownTabs: pane.tabs.count) ?? false }

    /// A pane of a pinned dock that takes no other tab (`allow_tabs` off): no tab drops on its strip.
    /// Home's dock takes tabs (Leo 2026-10-21), so this is only a dock the person closed to tabs.
    var isClosedPinnedDockPane: Bool { pinnedDock.map { !$0.takesTabs } ?? false }

    /// A pane of Home's pinned dock while it takes tabs: a tab made there stays there, so what Home
    /// opens beside itself is made there and then moved to a column on its right (``HomeDockOpens``).
    var isOpenPinnedDockPane: Bool { pinnedDock?.allowsTabs == true }

    /// The pinned dock this pane is in, if any.
    private var pinnedDock: DockColumn? { HomeDockOpens.pinnedDock(holding: pane, in: daemon.store) }

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
