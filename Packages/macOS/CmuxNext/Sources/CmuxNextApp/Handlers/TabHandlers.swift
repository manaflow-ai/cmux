import AppKit
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
        registry.bind("newSurface", invoke: { ctx.paneController($0)?.newTerminalTab() })
        registry.bind("openBrowser", invoke: { invocation in
            var url: URL?
            if let text = invocation["url"]?.stringValue {
                guard let resolved = BrowserURLResolver().url(for: text) else { return ctx.refuse(MiscHandlerStrings.invalidURL(text)) }
                url = resolved
            }
            ctx.paneController(invocation)?.newBrowserTab(url: url, engine: invocation["engine"]?.stringValue)
        })
        registry.bind("closeTab", invoke: { invocation in
            guard let (pane, id) = ctx.tab(invocation) else { return }
            pane.close([id])
        })
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
                pane.newBrowserTab(url: tab.url.flatMap(URL.init(string:)))
            } else if id.rawValue.hasPrefix(LocalBrowserTab.prefix) {
                pane.newBrowserTab(url: ctx.services.cache.existingBrowser(id.rawValue)?.tab.state.url)
            } else {
                pane.newTerminalTab(cwd: pane.tab(id)?.cwd)
            }
        })
        let history = ClosedTabTracker(services: ctx.services)
        registry.bind("reopenClosedBrowserPanel", invoke: { _ in
            guard let record = history.popLast() ?? ctx.refuse("no recently closed tab") else { return }
            history.reopen(record, fallback: ctx.services.windows.active?.focusedPane)
        })
    }

    private static func bindSelection(_ registry: ActionRegistry, _ ctx: AppActionContext) {
        registry.bind("nextSurface", invoke: { ctx.paneController($0)?.selectAdjacent(1) })
        registry.bind("prevSurface", invoke: { ctx.paneController($0)?.selectAdjacent(-1) })
        registry.bind("selectSurfaceByNumber", invoke: { invocation in
            guard let pane = ctx.paneController(invocation) else { return }
            guard let number = invocation["index"]?.intValue ?? ctx.refuse("an index 1-9 is required") else { return }
            let ids = pane.orderedIDs
            guard !ids.isEmpty else { return ctx.refuse("the pane has no tabs") }
            // Chrome: 9 always selects the last tab.
            pane.select(number >= 9 ? ids[ids.count - 1] : ids[min(number - 1, ids.count - 1)])
        })
        registry.bind("palette.goToTab", invoke: { invocation in
            guard let ref = invocation["tab"]?.targetValue ?? invocation.target ?? ctx.refuse("a tab argument is required") else { return }
            reveal(tabID: ref.id, ctx: ctx)
        })
    }

    /// Shows the tab's workspace in the active window, then selects and focuses it.
    static func reveal(tabID: String, ctx: AppActionContext) {
        guard let (_, paneModel) = ctx.services.locateTab(tabID) ?? ctx.refuse("no tab \(tabID)") else { return }
        if let pane = ctx.services.paneController(for: paneModel) {
            pane.select(StripTabID(tabID))
            pane.view.window?.makeKeyAndOrderFront(nil)
            return
        }
        guard let window = ctx.services.windows.active ?? ctx.refuse("no window is open") else { return }
        let workspace = ctx.services.daemon.store.workspaces.first { $0.screens.contains { $0.panes.contains { $0 === paneModel } } }
        guard let workspace else { return }
        window.state.selection.select(tabID, in: paneModel.id)
        window.state.focusedPane[workspace.id] = LayoutPaneID(paneModel.id)
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
        guard target != index else { return ctx.refuse("the tab is already at the edge") }
        pane.move(id, toPane: pane, index: target)
    }

    /// Previous or next pane in the active screen's visual order, wrapping.
    private static func moveToSiblingPane(_ ctx: AppActionContext, _ invocation: ActionInvocation, offset: Int) {
        guard let (pane, id) = ctx.tab(invocation), let content = pane.workspace else { return }
        guard let screen = content.layoutModel.screen(containing: pane.layoutPaneID) else { return }
        let order = screen.layout.panes
        guard order.count > 1, let index = order.firstIndex(of: pane.layoutPaneID) else {
            return ctx.refuse("the screen has no other pane")
        }
        let next = order[(index + offset + order.count) % order.count]
        guard let target = content.panes[next] else { return }
        pane.move(id, toPane: target, index: target.pane.tabs.count)
    }

    private static func moveToNeighborPane(_ ctx: AppActionContext, _ invocation: ActionInvocation, direction: LayoutDirection) {
        guard let (pane, id) = ctx.tab(invocation), let content = pane.workspace else { return }
        guard let neighbor = PaneHandlers.neighbor(of: pane.layoutPaneID, direction: direction, in: content),
              let target = content.panes[neighbor] else {
            return ctx.refuse("no pane \(direction) of the tab")
        }
        pane.move(id, toPane: target, index: target.pane.tabs.count)
    }

    private static func bindMetadata(_ registry: ActionRegistry, _ ctx: AppActionContext) {
        registry.bind("renameTab", invoke: { invocation in
            guard let (pane, id) = ctx.tab(invocation) else { return }
            guard let name = invocation["name"]?.stringValue, !name.isEmpty else { return pane.rename(id) }
            guard let surface = pane.tab(id)?.surface ?? ctx.refuse("session-local tabs cannot be renamed") else { return }
            rename(surface, to: name, ctx: ctx, pane: pane)
        })
        registry.bind("palette.clearTabName", invoke: { invocation in
            guard let (pane, id) = ctx.tab(invocation) else { return }
            guard let surface = pane.tab(id)?.surface ?? ctx.refuse("session-local tabs have no name") else { return }
            rename(surface, to: nil, ctx: ctx, pane: pane)
        })
        registry.bind("palette.toggleTabPin", invoke: { invocation in
            guard let (pane, id) = ctx.tab(invocation) else { return }
            guard let tab = pane.tab(id) ?? ctx.refuse("session-local tabs cannot be pinned") else { return }
            pane.setPinned(id, pinned: !tab.pinned)
        })
    }

    /// Optimistic rename; an empty name clears it on the daemon.
    static func rename(_ surface: SurfaceID, to name: String?, ctx: AppActionContext, pane: PaneController) {
        Task {
            let ok = await ctx.services.daemon.perform("rename-surface", patch: .renameTab(surface: surface, name: name)) { connection, _ in
                try await connection.renameTab(surface, to: name ?? "")
            }
            if !ok { pane.resyncStrip() }
        }
    }
}
