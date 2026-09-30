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
/// shows it through the store (optimistic where the store has a patch).
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
        registry.bind("openBrowser", invoke: { TabLifecycle.newBrowser(ctx, $0) })
        registry.bind("openBrowser.webkit", invoke: { TabLifecycle.newBrowser(ctx, $0, engine: .webkit) })
        let chromiumReason: @MainActor () -> String? = { ctx.services.cache.browserTabs?.cefUnavailableReason() }
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
            pane.close(tabs[..<index].filter { !$0.isPinned }.map(\.id))
        })
        registry.bind("duplicateTab", invoke: { invocation in
            guard let (pane, id) = ctx.tab(invocation) else { return }
            if let tab = pane.tab(id), tab.kind == .browser {
                // Same engine as the original (cookies live in one engine).
                let live = ctx.services.cache.existingBrowser(tab.id)?.tab.state.url
                pane.newBrowserTab(url: live ?? tab.url.flatMap(URL.init(string:)), inherited: tab.browserEngine)
            } else if id.rawValue.hasPrefix(LocalBrowserTab.prefix) {
                pane.newBrowserTab(url: ctx.services.cache.existingBrowser(id.rawValue)?.tab.state.url)
            } else if id.rawValue.hasPrefix(LocalAgentTab.prefix) {
                pane.newAgentTab()
            } else {
                pane.newTerminalTab(cwd: pane.tab(id)?.cwd)
            }
        })
        let history = ClosedTabTracker(services: ctx.services)
        ctx.services.closedTabs = history
        registry.bind("reopenClosedBrowserPanel", invoke: { _ in
            guard let record = history.popLast() ?? ctx.refuse(RefusalStrings.noRecentlyClosedTab) else { return }
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
            guard !ids.isEmpty else { return ctx.refuse(RefusalStrings.paneHasNoTabs) }
            // Chrome: 9 always selects the last tab.
            pane.select(number >= 9 ? ids[ids.count - 1] : ids[min(number - 1, ids.count - 1)])
        })
        registry.bind("palette.goToTab", invoke: { invocation in
            guard let ref = invocation["tab"]?.targetValue ?? invocation.target ?? ctx.refuse(RefusalStrings.tabArgumentRequired) else { return }
            reveal(tabID: ref.id, ctx: ctx)
        })
    }

    /// Shows the tab's workspace in the active window, then selects and focuses it.
    static func reveal(tabID: String, ctx: AppActionContext) {
        guard let (_, paneModel) = ctx.services.locateTab(tabID) ?? ctx.refuse(RefusalStrings.noTab(tabID)) else { return }
        if let pane = ctx.services.paneController(for: paneModel) {
            pane.select(StripTabID(tabID))
            if let window = pane.view.window { WindowActivation.show(window, .raise) }
            return
        }
        guard let window = ctx.services.windows.active ?? ctx.refuse(RefusalStrings.noWindowOpen) else { return }
        let workspace = ctx.services.activeDaemon.store.workspaces.first { $0.screens.contains { $0.panes.contains { $0 === paneModel } } }
        guard let workspace else { return }
        window.state.selection.select(tabID, in: paneModel.id)
        window.focus.send(.selectTab(pane: paneModel.id, tab: tabID, workspace: workspace.id, source: .intent))
        ctx.services.windows.show(workspaceID: workspace.id, in: window.state)
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
        guard target != index else { return ctx.refuse(RefusalStrings.tabAtEdge) }
        pane.move(id, toPane: pane, index: target)
    }

    /// Previous or next pane in the active screen's visual order, wrapping.
    private static func moveToSiblingPane(_ ctx: AppActionContext, _ invocation: ActionInvocation, offset: Int) {
        guard let (pane, id) = ctx.tab(invocation), let content = pane.workspace else { return }
        guard let screen = content.layoutModel.screen(containing: pane.layoutPaneID) else { return }
        let order = screen.layout.panes
        guard order.count > 1, let index = order.firstIndex(of: pane.layoutPaneID) else {
            return ctx.refuse(RefusalStrings.screenHasNoOtherPane)
        }
        let next = order[(index + offset + order.count) % order.count]
        guard let target = content.panes[next] else { return }
        pane.move(id, toPane: target, index: target.pane.tabs.count)
    }

    private static func moveToNeighborPane(_ ctx: AppActionContext, _ invocation: ActionInvocation, direction: LayoutDirection) {
        guard let (pane, id) = ctx.tab(invocation), let content = pane.workspace else { return }
        guard let neighbor = PaneHandlers.neighbor(of: pane.layoutPaneID, direction: direction, in: content),
              let target = content.panes[neighbor] else {
            return ctx.refuse(RefusalStrings.noPaneInDirectionOfTab(RefusalStrings.direction(direction)))
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
        registry.bind("palette.toggleTabPin", unavailable: ctx.needs(DaemonCapabilities.tabMetadata), invoke: { invocation in
            if TabLifecycle.togglePinHidden(ctx, invocation) { return }
            guard let (pane, id) = ctx.tab(invocation) else { return }
            guard let tab = pane.tab(id) ?? ctx.refuse(RefusalStrings.sessionLocalCannotPin) else { return }
            pane.setPinned(id, pinned: !tab.pinned)
        })
    }

    /// Optimistic rename; an empty name clears it on the daemon.
    static func rename(_ surface: SurfaceID, to name: String?, ctx: AppActionContext, pane: PaneController) {
        let daemon = ctx.services.activeDaemon
        ctx.registry.track(Task {
            let ok = await daemon.perform("rename-surface", patch: .renameTab(surface: surface, name: name)) { connection, _ in
                try await connection.renameTab(surface, to: name ?? "")
            }
            if !ok { pane.resyncStrip() }
            return ok ? nil : "rename-surface failed (see the app log)"
        })
    }
}
