import AppKit
import CmuxNextDesign
import CmuxNextActions
import CmuxNextBridge
import CmuxNextBrowser
import CmuxNextDaemon
import CmuxNextLayout

/// Tab actions (category `.tab` except `tabGroup.*`): create, close,
/// select, reorder, rename, pin, and move to other panes, splits, columns,
/// workspaces, and windows. Every change is a daemon command; the strip
/// shows it through the store (a store intent where one exists).
enum TabHandlers {
    static func bind(into registry: ActionRegistry, context ctx: AppActionContext) {
        bindLifecycle(registry, ctx)
        bindSelection(registry, ctx)
        bindMoves(registry, ctx)
        bindMetadata(registry, ctx)
        TabHandlers.bindMoreActions(into: registry, context: ctx)
    }

    private static func bindLifecycle(_ registry: ActionRegistry, _ ctx: AppActionContext) {
        registry.bind("newSurface", invoke: { TabLifecycle.newTerminal(ctx, $0) })
        registry.bind("newTab.sameKind", invoke: { TabLifecycle.newTabOfPaneKind(ctx, $0) })
        registry.bind(NewTabPage.action, invoke: { ctx.paneController($0)?.newTabPage() })
        registry.bind(NewTabSubmit.action, invoke: { NewTabSubmit.run($0, ctx) })
        registry.bind(NewTabPage.focusLocation, invoke: { ctx.paneController($0)?.focusLocation($0) })
        registry.bind("openBrowser", invoke: { TabLifecycle.newBrowser(ctx, $0) })
        registry.bind("openBrowser.webkit", invoke: { TabLifecycle.newBrowser(ctx, $0, engine: .webkit) })
        let chromiumReason: @MainActor () -> String? = { ctx.services.cache.browserTabs.cefUnavailableReason() }
        registry.bind("openBrowser.chromium", unavailable: chromiumReason, invoke: { TabLifecycle.newBrowser(ctx, $0, engine: .cef) })
        registry.bind("browser.openInChromium", unavailable: chromiumReason, invoke: { TabLifecycle.reopen(ctx, $0, on: .cef) })
        registry.bind("browser.openInWebKit", invoke: { TabLifecycle.reopen(ctx, $0, on: .webkit) })
        registry.bind("closeTab", invoke: { TabLifecycle.close(ctx, $0) })
        registry.bind("closeOtherTabsInPane", invoke: { invocation in
            guard let (pane, id) = ctx.tab(invocation) else { return }
            pane.handle(.closeOthers(keeping: id))
        })
        registry.bind("closeTabsToRight", invoke: { invocation in
            guard let (pane, id) = ctx.tab(invocation) else { return }
            pane.handle(.closeToRight(of: id))
        })
        registry.bind("closeTabsToLeft", invoke: { invocation in
            guard let (pane, id) = ctx.tab(invocation) else { return }
            let tabs = pane.stripModel.orderedTabs
            guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
            CloseUndoToasts.close(in: pane, tabs[..<index].filter { !$0.isPinned }.map(\.id))
        })
        registry.bind("duplicateTab", invoke: { invocation in
            guard let (pane, id) = ctx.tab(invocation) else { return }
            if let tab = pane.tab(id), tab.kind == .browser {
                // Same engine as the original (cookies live in one engine).
                let live = ctx.services.cache.existingBrowser(tab.id)?.tab.state.url
                pane.newBrowserTab(url: live ?? tab.url.flatMap(URL.init(string:)), inherited: tab.browserEngine)
            } else if id.rawValue.hasPrefix(LocalBrowserTab.prefix) {
                pane.newBrowserTab(url: ctx.services.cache.existingBrowser(id.rawValue)?.tab.state.url)
            } else if ctx.services.agentTabs.isAgentTab(id.rawValue) {
                pane.duplicateAgentTab(id.rawValue)
            } else if id.rawValue.hasPrefix(LocalPageTab.prefix) || pane.tab(id)?.page != nil {
                // One tab per page per window: the page is already there.
                return
            } else {
                pane.newTerminalTab(cwd: pane.tab(id)?.cwd)
            }
        })
        let history = ClosedTabTracker(services: ctx.services)
        ctx.services.closedTabs = history
        registry.bind("reopenClosedBrowserPanel", invoke: { _ in
            // The daemon's history first; the app's tracker covers daemons without it.
            if let entry = DaemonClosedHistory.entries([.tab], in: ctx.services).first {
                return DaemonClosedHistory.reopen(entry, services: ctx.services)
            }
            guard let record = history.popLast() ?? ctx.refuseQuietly(RefusalStrings.noRecentlyClosedTab) else { return }
            history.reopen(record, fallback: ctx.services.windows.active?.focusedPane)
        })
    }

    private static func bindSelection(_ registry: ActionRegistry, _ ctx: AppActionContext) {
        registry.bind("nextSurface", invoke: { ctx.paneController($0)?.selectAdjacent(1) })
        registry.bind("prevSurface", invoke: { ctx.paneController($0)?.selectAdjacent(-1) })
        registry.bind("selectSurfaceByNumber", invoke: { invocation in
            guard let pane = ctx.paneController(invocation) else { return }
            guard let number = invocation["index"]?.intValue ?? ctx.refuse(RefusalStrings.indexRequired) else { return }
            let ids = pane.orderedIDs
            guard !ids.isEmpty else { return ctx.refuseQuietly(RefusalStrings.paneHasNoTabs) }
            // 9 always selects the last tab.
            pane.select(number >= 9 ? ids[ids.count - 1] : ids[min(number - 1, ids.count - 1)])
        })
        // `palette.goToTab` is an alias of `tab.search`, which TabSearchHandlers binds (a tab target
        // reveals the tab, as here; no target opens Search Tabs). A second bind here replaced it.
        // `cmux tab <id> focus`: the same path, by target.
        registry.bind("tab.focus", invoke: { invocation in
            guard let ref = invocation.target ?? ctx.scope(invocation).tab.map({ ActionTargetRef(kind: .tab, id: $0.id.rawValue) })
                ?? ctx.refuse(RefusalStrings.tabArgumentRequired) else { return }
            reveal(tabID: ref.id, ctx: ctx)
        })
        // `cmux pane <id> focus` / `cmux screen <id> focus`: the same reveal, by target.
        registry.bind("pane.focus", invoke: { invocation in
            guard let ref = invocation.target, ref.kind == .pane else { return ctx.refuse(RefusalStrings.paneArgumentRequired) }
            revealPane(paneID: ref.id, ctx: ctx)
        })
        registry.bind("screen.focus", invoke: { invocation in
            guard let ref = invocation.target, ref.kind == .screen else { return ctx.refuse(RefusalStrings.noScreen("")) }
            revealScreen(screenID: ref.id, ctx: ctx)
        })
    }

    /// Shows the tab in the window that lists its workspace (the active
    /// window takes the workspace when no window lists it), selects it and
    /// focuses its pane. Selection is the window's (state-ownership.md 3);
    /// the change is saved in the window's record at once.
    static func reveal(tabID: String, ctx: AppActionContext) {
        // tab.focus and Go to Tab focus by purpose (`focuses`); any other
        // caller only with the run's view-change permission.
        guard ActionRunScope.viewChangeAllowed() else { return }
        guard let (tab, paneModel) = ctx.services.locateTab(tabID) ?? ctx.notFound(RefusalStrings.noTab(tabID)) else { return }
        guard let (workspace, screen) = owner(of: paneModel, ctx) ?? ctx.notFound(RefusalStrings.noTab(tabID)) else { return }
        reveal(workspace: workspace, screen: screen, pane: paneModel, tab: tab, ctx: ctx)
    }

    /// pane.focus: the pane's workspace and screen shown, the pane focused.
    static func revealPane(paneID: String, ctx: AppActionContext) {
        guard ActionRunScope.viewChangeAllowed() else { return }
        for (workspace, _) in ctx.services.machines.allWorkspaces {
            for screen in workspace.screens {
                if let pane = screen.panes.first(where: { $0.id == paneID || $0.resourceID?.rawValue == paneID }) {
                    return reveal(workspace: workspace, screen: screen, pane: pane, tab: nil, ctx: ctx)
                }
            }
        }
        let _: Bool? = ctx.notFound(RefusalStrings.noPaneID(paneID))
    }

    /// screen.focus: the screen's workspace shown, the screen selected.
    static func revealScreen(screenID: String, ctx: AppActionContext) {
        guard ActionRunScope.viewChangeAllowed() else { return }
        for (workspace, _) in ctx.services.machines.allWorkspaces {
            if let screen = workspace.screens.first(where: { $0.id == screenID || $0.resourceID?.rawValue == screenID }) {
                return reveal(workspace: workspace, screen: screen, pane: nil, tab: nil, ctx: ctx)
            }
        }
        let _: Bool? = ctx.notFound(RefusalStrings.noScreen(screenID))
    }

    private static func owner(of pane: PaneModel, _ ctx: AppActionContext) -> (WorkspaceModel, ScreenModel)? {
        for (workspace, _) in ctx.services.machines.allWorkspaces {
            if let screen = workspace.screens.first(where: { $0.panes.contains { $0 === pane } }) { return (workspace, screen) }
        }
        return nil
    }

    /// The one reveal of tab.focus, pane.focus and screen.focus: the window
    /// that lists `workspace` shows it, `screen` is selected there, then
    /// `tab` (selected and focused) or `pane` (focused); the window's record
    /// is saved and the window raised.
    private static func reveal(workspace: WorkspaceModel, screen: ScreenModel, pane: PaneModel?, tab: TabModel?, ctx: AppActionContext) {
        guard let controller = ctx.window(showing: workspace.id) ?? ctx.refuse(RefusalStrings.noWindowOpen) else { return }
        // The window's observer swaps the content on a later turn; swap it
        // now (idempotent), so the screen is selected in this workspace's
        // content and not dropped (screen.focus from Home, chwsr4 E2E).
        if controller.content?.workspace !== workspace { controller.showWorkspace(requested: workspace.id) }
        if let content = controller.content, content.workspace === workspace {
            ScreenCommands.select(LayoutScreenID(screen.id), in: content)
        }
        if let tab, let pane {
            controller.state.selection.select(tab.id, in: pane.id)
            controller.focus.send(.selectTab(pane: pane.id, tab: tab.id, workspace: workspace.id, source: .intent))
            ctx.services.paneController(for: pane)?.select(StripTabID(tab.id))
        } else if let pane {
            controller.focus.send(.focusPane(pane.id, workspace: workspace.id, source: .intent))
        }
        ctx.services.windows.recordSaver.stateDidChange(controller.state)
        if let window = controller.window { WindowActivation.show(window, .raise) }
    }

    private static func bindMoves(_ registry: ActionRegistry, _ ctx: AppActionContext) {
        registry.bind("moveSurfaceLeft", invoke: { reorder(ctx, $0, by: -1) })
        registry.bind("moveSurfaceRight", invoke: { reorder(ctx, $0, by: 1) })
        registry.bind("moveSurfaceToPreviousPane", invoke: { moveToSiblingPane(ctx, $0, offset: -1) })
        registry.bind("moveSurfaceToNextPane", invoke: { moveToSiblingPane(ctx, $0, offset: 1) })
        let directions: [(ActionID, LayoutDirection)] = [
            ("moveSurfaceToPaneLeft", .left), ("moveSurfaceToPaneRight", .right),
            ("moveSurfaceToPaneUp", .up), ("moveSurfaceToPaneDown", .down),
        ]
        for (id, direction) in directions {
            registry.bind(id, invoke: { moveToNeighborPane(ctx, $0, direction: direction) })
        }
    }

    private static func reorder(_ ctx: AppActionContext, _ invocation: ActionInvocation, by offset: Int) {
        guard let (pane, id) = ctx.tab(invocation) else { return }
        let ids = pane.orderedIDs
        guard let index = ids.firstIndex(of: id) else { return }
        let target = min(max(index + offset, 0), ids.count - 1)
        guard target != index else { return ctx.refuseQuietly(RefusalStrings.tabAtEdge) }
        pane.move(id, toPane: pane, index: target)
    }

    /// Previous or next pane in the active screen's visual order, wrapping.
    private static func moveToSiblingPane(_ ctx: AppActionContext, _ invocation: ActionInvocation, offset: Int) {
        guard let (pane, id) = ctx.tab(invocation), let content = pane.workspace else { return }
        guard let screen = content.layoutModel.screen(containing: pane.layoutPaneID) else { return }
        let order = screen.layout.panes
        guard order.count > 1, let index = order.firstIndex(of: pane.layoutPaneID) else {
            return ctx.refuseQuietly(RefusalStrings.screenHasNoOtherPane)
        }
        let next = order[(index + offset + order.count) % order.count]
        guard let target = content.panes[next] else { return }
        pane.move(id, toPane: target, index: target.pane.tabs.count)
    }

    private static func moveToNeighborPane(_ ctx: AppActionContext, _ invocation: ActionInvocation, direction: LayoutDirection) {
        guard let (pane, id) = ctx.tab(invocation), let content = pane.workspace else { return }
        guard let neighbor = PaneHandlers.neighbor(of: pane.layoutPaneID, direction: direction, in: content),
              let target = content.panes[neighbor] else {
            return ctx.refuseQuietly(RefusalStrings.noPaneInDirectionOfTab(RefusalStrings.direction(direction)))
        }
        pane.move(id, toPane: target, index: target.pane.tabs.count)
    }

    private static func bindMetadata(_ registry: ActionRegistry, _ ctx: AppActionContext) {
        registry.bind("renameTab", invoke: { invocation in
            if TabLifecycle.renameHidden(ctx, invocation, name: invocation["name"]?.stringValue) { return }
            guard let (pane, id) = ctx.tab(invocation) else { return }
            guard let name = invocation["name"]?.stringValue, !name.isEmpty else { return pane.rename(id) }
            guard let surface = pane.tab(id)?.surface ?? ctx.refuse(RefusalStrings.sessionLocalCannotRename) else { return }
            rename(surface, to: name, ctx: ctx, pane: pane)
        })
        registry.bind("palette.clearTabName", invoke: { invocation in
            if TabLifecycle.renameHidden(ctx, invocation, name: "") { return }
            guard let (pane, id) = ctx.tab(invocation) else { return }
            guard let surface = pane.tab(id)?.surface ?? ctx.refuse(RefusalStrings.sessionLocalHasNoName) else { return }
            rename(surface, to: nil, ctx: ctx, pane: pane)
        })
        registry.bind("palette.toggleTabPin", unavailable: ctx.needs(DaemonCapabilities.shared.tabMetadata), invoke: { invocation in
            let commands = PinCommands(context: ctx)
            if invocation.target?.kind == .tab || invocation["tab"]?.targetValue != nil {
                guard let (tab, _) = ctx.daemonTab(invocation) else { return }
                return commands.setTabPinned(tab.id, pinned: !tab.pinned, origin: invocation.origin)
            }
            guard let (pane, id) = ctx.tab(invocation) else { return }
            guard let tab = pane.tab(id) ?? ctx.refuse(RefusalStrings.sessionLocalCannotPin) else { return }
            commands.setTabPinned(id.rawValue, pinned: !tab.pinned, origin: invocation.origin)
        })
        // The tab menu reads Pin Tab or Unpin Tab for the right-clicked tab.
        ActionTargetTitles.set("palette.toggleTabPin", in: registry) { invocation in
            guard let id = invocation.target?.id, let (tab, _) = ctx.services.locateTab(id) else { return nil }
            return tab.pinned ? PinStrings.unpinTab : PinStrings.pinTab
        }
    }

    /// Optimistic rename; an empty name clears it on the daemon.
    static func rename(_ surface: SurfaceID, to name: String?, ctx: AppActionContext, pane: PaneController) {
        let daemon = ctx.services.activeDaemon
        ctx.registry.track(Task {
            let ok = await daemon.intend("rename-surface", .renameTab(surface: surface, name: name)) { connection in
                try await connection.renameTab(surface, to: name ?? "")
            }
            if !ok { pane.resyncStrip() }
            return ok ? nil : "rename-surface failed (see the app log)"
        })
    }
}
