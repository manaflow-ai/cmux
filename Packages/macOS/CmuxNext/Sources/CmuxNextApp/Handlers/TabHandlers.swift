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
        PaneTabBarHandlers.bind(into: registry, context: ctx)
        TabRestart.bind(into: registry, context: ctx)
    }

    private static func bindLifecycle(_ registry: ActionRegistry, _ ctx: AppActionContext) {
        registry.bind("newSurface", invoke: { TabLifecycle.newTerminal(ctx, $0) })
        registry.bind("newTab.default", invoke: { TabLifecycle.newTabOfPaneKind(ctx, $0) })
        registry.bind("newTab.ofKind", invoke: { TabLifecycle.newTabOfPaneKind(ctx, $0, followsSetting: false) })
        registry.bind("newTab.toRight", invoke: { TabLifecycle.newTabOfPaneKind(ctx, $0, position: .afterCurrent) })
        // Cmd-T's tab in a named place, whatever `tabs.newTabPosition` says (Lawrence 2026-10-20).
        registry.bind("newTab.afterCurrent", invoke: { TabLifecycle.newTabOfPaneKind(ctx, $0, position: .afterCurrent) })
        registry.bind("newTab.atStart", invoke: { TabLifecycle.newTabOfPaneKind(ctx, $0, position: .start) })
        registry.bind("newTab.atEnd", invoke: { TabLifecycle.newTabOfPaneKind(ctx, $0, position: .end) })
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
        // Close Other Tabs keeps every selected tab when the menu is on one of several (Chrome).
        // Each close names what it closes; with nothing to close the row is disabled with the reason.
        let closes: [(ActionID, String, @MainActor (AppActionContext, ActionInvocation, PaneController, StripTabID) -> [StripTabID])] = [
            ("closeOtherTabsInPane", RefusalStrings.noOtherTabsToClose, { ctx, invocation, pane, id in
                pane.stripModel.closedByCloseOthers(keepingAll: ctx.actingTabs(invocation, pane, id)) }),
            ("closeTabsToRight", RefusalStrings.noTabsToTheRight, { _, _, pane, id in pane.stripModel.closedByCloseToRight(of: id) }),
            ("closeTabsToLeft", RefusalStrings.noTabsToTheLeft, { _, _, pane, id in pane.stripModel.closedByCloseToLeft(of: id) }),
        ]
        for (id, none, closing) in closes {
            registry.bind(id, invoke: { invocation in
                guard let (pane, tab) = ctx.tab(invocation) else { return }
                let closed = closing(ctx, invocation, pane, tab)
                guard !closed.isEmpty else { return ctx.refuse(none) }
                CloseUndoToasts.close(in: pane, closed)
            })
            ctx.setTargetReason(id) { invocation in
                ctx.tab(invocation).flatMap { pane, tab in closing(ctx, invocation, pane, tab).isEmpty ? none : nil }
            }
        }
        registry.bind("duplicateTab", invoke: { invocation in
            guard let (pane, clicked) = ctx.tab(invocation) else { return }
            let ids = ctx.actingTabs(invocation, pane, clicked)
            guard !ids.allSatisfy({ isPageTab($0, in: pane, ctx) }) else { return ctx.refuse(RefusalStrings.pageTabOpensOnce) }
            for id in ids {
                if let tab = pane.tab(id), tab.kind == .browser {
                    // Same engine as the original (cookies live in one engine), next to it, with its history.
                    BrowserTabDuplicate(pane: pane).open(tab)
                } else if id.rawValue.hasPrefix(LocalBrowserTab.prefix) {
                    pane.newBrowserTab(url: ctx.services.cache.existingBrowser(id.rawValue)?.tab.state.url)
                } else if ctx.services.agentTabs.isAgentTab(id.rawValue) {
                    pane.duplicateAgentTab(id.rawValue)
                } else if isPageTab(id, in: pane, ctx) {
                    // One tab per page per window: the page is already there.
                    continue
                } else {
                    pane.newTerminalTab(cwd: pane.tab(id)?.cwd)
                }
            }
        })
        // A page tab alone (or a selection of only page tabs) has nothing to duplicate.
        ctx.setTargetReason("duplicateTab") { invocation in
            ctx.tab(invocation).flatMap { pane, clicked in
                ctx.actingTabs(invocation, pane, clicked).allSatisfy { isPageTab($0, in: pane, ctx) } ? RefusalStrings.pageTabOpensOnce : nil
            }
        }
        ctx.services.closedTabs = ClosedTabsFeed(services: ctx.services)
        // Cmd-Shift-T (reopen-closed.md 4): the newest closed group of the key window at any
        // level, from the daemon's closed history (the only one); a window the app closed is a
        // `window` group there (`window-records-v1`). With no group to reopen (an older daemon, a
        // record write that failed) the app's registry reopens the last closed window.
        registry.bind("reopenClosedBrowserPanel", invoke: { _ in
            if let entry = DaemonClosedHistory.newest(for: ctx.services.windows.active?.state.id, in: ctx.services) {
                return DaemonClosedHistory.reopen(entry, services: ctx.services)
            }
            if ctx.services.windows.reopenClosedWindow() { return }
            guard DaemonClosedHistory.isServed(in: ctx.services) else {
                return ctx.refuse(RefusalStrings.needsDaemonCapability(DaemonCapability.stateResources.rawValue))
            }
            ctx.refuseQuietly(RefusalStrings.noRecentlyClosedTab)
        })
    }

    /// A page tab, which Duplicate Tab leaves alone (one tab per page per window); a browser or
    /// agent tab duplicates even when it shows a page.
    private static func isPageTab(_ id: StripTabID, in pane: PaneController, _ ctx: AppActionContext) -> Bool {
        if pane.tab(id)?.kind == .browser || id.rawValue.hasPrefix(LocalBrowserTab.prefix) || ctx.services.agentTabs.isAgentTab(id.rawValue) {
            return false
        }
        return id.rawValue.hasPrefix(LocalPageTab.prefix) || pane.tab(id)?.page != nil
    }

    private static func bindSelection(_ registry: ActionRegistry, _ ctx: AppActionContext) {
        registry.bind("navigate.next", invoke: { _ in PreviousNext.step(by: 1, ctx.services) })
        registry.bind("navigate.previous", invoke: { _ in PreviousNext.step(by: -1, ctx.services) })
        registry.bind("nextSurface", invoke: { ctx.paneController($0)?.selectAdjacent(1) })
        registry.bind("prevSurface", invoke: { ctx.paneController($0)?.selectAdjacent(-1) })
        registry.bind("selectSurfaceByNumber", invoke: { invocation in
            guard let pane = ctx.paneController(invocation) else { return }
            guard let number = invocation["index"]?.intValue ?? ctx.refuse(RefusalStrings.indexRequired) else { return }
            // The tabs the strip shows: a member of a collapsed group has no visible number.
            let ids = pane.stripModel.visibleOrderedTabs.map(\.id)
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
        // A pinned tab moves among the pinned tabs, an unpinned one among the rest (Chrome):
        // the daemon puts a move across the boundary back, so it would do nothing.
        guard let target = pane.stripModel.moveIndex(of: id, by: offset) else { return ctx.refuseQuietly(RefusalStrings.tabAtEdge) }
        pane.move(id, toPane: pane, index: target)
    }

    /// Previous or next pane in the active screen's visual order, wrapping.
    private static func moveToSiblingPane(_ ctx: AppActionContext, _ invocation: ActionInvocation, offset: Int) {
        guard let (pane, id) = ctx.tab(invocation), let content = pane.workspace else { return }
        guard let screen = content.layoutModel.screen(containing: pane.layoutPaneID) else { return }
        let order = screen.layout.visualPanes
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
        registry.bind("palette.toggleTabPin", unavailable: ctx.needs(DaemonCapability.tabMetadata.rawValue), invoke: { invocation in
            let commands = PinCommands(context: ctx)
            if invocation.target?.kind == .tab || invocation["tab"]?.targetValue != nil {
                guard let (tab, pane) = ctx.daemonTab(invocation) else { return }
                // On one of several selected tabs, Pin pins them all unless all are pinned (Chrome's Pin Tabs).
                let strip = invocation.actsOnTabSelection ? ctx.services.paneController(for: pane)?.stripModel : nil
                let ids = strip?.actingTabs(for: StripTabID(tab.id)) ?? [StripTabID(tab.id)], pin = strip?.pinsAll(ids) ?? !tab.pinned
                return ids.forEach { commands.setTabPinned($0.rawValue, pinned: pin, origin: invocation.origin) }
            }
            guard let (pane, id) = ctx.tab(invocation) else { return }
            guard let tab = pane.tab(id) ?? ctx.refuse(RefusalStrings.sessionLocalCannotPin) else { return }
            commands.setTabPinned(id.rawValue, pinned: !tab.pinned, origin: invocation.origin)
        })
        // A tab only this app holds (an internal page, a session-only browser tab) has no daemon
        // record to pin: its menu has no Pin row, rather than one that refuses.
        ActionTargetVisibility.hide("palette.toggleTabPin", in: registry) { invocation in
            guard invocation.target?.kind == .tab, let id = invocation.target?.id else { return false }
            return id.hasPrefix(LocalBrowserTab.prefix) || id.hasPrefix(LocalPageTab.prefix)
        }
        // The tab menu reads Pin Tab or Unpin Tab for the right-clicked tab.
        ActionTargetTitles.set("palette.toggleTabPin", in: registry) { invocation in
            guard let id = invocation.target?.id, let (tab, _) = ctx.services.locateTab(id) else { return nil }
            return tab.pinned ? PinStrings.unpinTab : PinStrings.pinTab
        }
        PinnedPage.bind(registry, ctx: ctx)
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
