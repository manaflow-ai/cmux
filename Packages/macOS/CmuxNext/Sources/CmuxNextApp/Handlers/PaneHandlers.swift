import AppKit
import CmuxNextActions
import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextLayout

/// Pane and split actions (category `.pane` except columns and screens):
/// split in four directions, focus, swap, resize, equalize, zoom, close,
/// rename, and workspace font size. Structure changes are daemon commands;
/// divider moves go through the layout model so they carry a gesture
/// transaction like a drag.
enum PaneHandlers {
    static func bind(into registry: ActionRegistry, context ctx: AppActionContext) {
        bindSplits(registry, ctx)
        bindFocus(registry, ctx)
        bindSizing(registry, ctx)
        PaneHandlers.bindPaneVerbs(into: registry, context: ctx)
    }

    // MARK: Geometry helpers

    /// The pane next to `pane` in `direction` on its screen, by displayed
    /// frames and the window's focus history (the most recently focused of
    /// several adjacent panes, and of a strip column; focus.md section 4a).
    static func neighbor(of pane: LayoutPaneID, direction: LayoutDirection, in content: WorkspaceContentController) -> LayoutPaneID? {
        guard let screen = content.layoutModel.screen(containing: pane) else { return nil }
        // One logical line: docked columns before and after the strip.
        let frames = content.layoutView.navigationFrames
        return FocusNavigation.neighbor(of: pane, direction: direction, frames: frames,
                                        recency: content.recentPanes,
                                        columns: screen.layout.columns.map(\.root.panes))
    }

    static func focus(_ pane: LayoutPaneID, in content: WorkspaceContentController) {
        content.focus.send(.focusPane(pane.rawValue, source: .intent))
    }

    /// A pane-navigation key (Focus Pane Left, Next Pane, a pane number, a column key) moves focus
    /// where the person asked, so the layout records a keyboard move: no without-a-click flash.
    static func focusByKey(_ pane: LayoutPaneID, in content: WorkspaceContentController) {
        DebugPaneFocus.began(content.focus)
        content.layoutModel.focus(pane, notify: false, source: .keyboard)
        focus(pane, in: content)
    }

    // MARK: Splits

    private static func bindSplits(_ registry: ActionRegistry, _ ctx: AppActionContext) {
        let splits: [(ActionID, PaneDirection)] = [("splitRight", .right), ("splitDown", .down), ("splitLeft", .left), ("splitUp", .up)]
        for (id, direction) in splits {
            registry.bind(id, invoke: { split(ctx, $0, direction: direction) })
        }
        registry.bind("newPaneAutoLayout", invoke: { invocation in
            guard let focused = ctx.paneController(invocation), focused.workspace != nil else { return }
            // Zellij's new pane: the largest shown scrolling pane, never a docked
            // column; a run that names a pane splits that one (PanePlacementRouting).
            let pane = PanePlacementRouting.autoLayoutTarget(ctx, invocation, from: focused)
            let aimed = pane === focused ? invocation : PanePlacementRouting.aimed(invocation, at: pane.pane, from: focused)
            // The longer side first; the other axis when only it has room; split refuses when neither has.
            let (preferred, fitting) = PanePlacementRouting.autoLayoutDirection(ctx, pane)
            split(ctx, aimed, direction: fitting ?? preferred)
        })
    }

    /// Splits the targeted pane (a shown one or any daemon pane, so the CLI
    /// can split a background workspace). Left and up split right or down,
    /// then swap the original into the new slot, so the new pane lands on
    /// that side. A shown workspace focuses the new pane.
    static func split(_ ctx: AppActionContext, _ invocation: ActionInvocation, direction: PaneDirection) {
        guard let pane = ctx.daemonPane(invocation) else { return }
        // The pane's own daemon: a CLI run can target a pane of a machine
        // other than the active window's.
        let daemon = ctx.services.daemon(for: pane)
        guard daemon.connection != nil else { return ctx.refuse(MiscHandlerStrings.daemonOffline) }
        let controller = ctx.services.paneController(for: pane)
        let content = controller?.workspace
        let handle = pane.handle
        // Ghostty's `split-inherit-working-directory = false`: the home folder (NewTerminalStart).
        let named = invocation["cwd"]?.stringValue
            ?? NewTerminalStart.uninherited(.split, services: ctx.services, daemon: daemon, besides: controller?.selectedTab)
        // Else the folder of the tab it splits: a terminal's, or an agent chat's exact folder.
        let inherited = named ?? NewTerminalStart.inherited(besides: controller?.selectedTab, in: pane, services: ctx.services)
        let cwd = inherited ?? controller?.selectedTab?.cwd ?? pane.tabs.first?.cwd
        let workspace = ctx.services.workspaceKey(of: pane)
        let keep = invocation["keep"]?.boolValue == true ? true : nil
        let logger = ctx.services.daemon.logger
        // The one tool-split rule (AppServices.toolSplit, cx-yihq): never a new column; from the
        // docked chat, a person's terminal opens as a tab in the strip (its cwd the explicit one,
        // else the chat's, else the daemon's resolver, NEW-TERMINAL-INHERITS-CWD).
        // A person's split of a browser tab, the New Tab page or a chat opens the New Tab page (cx-jfo7),
        // unless it asked for a terminal (the chat header's Terminal).
        let page = !invocation.opensTerminal && NewTabPage.splitsToPage(controller, direction: direction, byPerson: invocation.origin == .user)
        switch ctx.services.toolSplit(from: pane, edge: edge(direction), byPerson: invocation.origin == .user) {
        case .split:
            if page, let controller { NewTabPage.split(controller, edge: edge(direction)); return }
        case .refused(let reason):
            return ctx.refuse(reason)
        case .tab(let strip):
            if let content = strip.workspace { focus(strip.layoutPaneID, in: content) }
            if page { return strip.newTabPage() }
            return strip.newTerminalTab(cwd: inherited, keep: keep, fromSelectedTab: true, daemonResolvesCwd: true)
        case .besideDock(let dock):
            // Every direction is a column on the dock's right: the pinned dock neither splits nor moves.
            if page { NewTabPage.split(dock, edge: .right); return }
            dock.workspace?.newColumn(after: dock.layoutPaneID, options: SpawnOptions(cwd: cwd, workspace: workspace, keep: keep))
            return
        }
        let axis: SplitAxis = direction == .left || direction == .right ? .horizontal : .vertical
        let sizing = controller.flatMap { controller in
            content?.layoutModel.splitSizingChanges(splitting: controller.layoutPaneID, axis: axis)
        } ?? []
        let daemonDirection: SplitDirection = direction == .left || direction == .right ? .right : .down
        let swapTowards: PaneDirection? = switch direction {
        case .left: .right
        case .up: .down
        default: nil
        }
        let intent = content?.beginFocusIntent()
        let command = PaneSplitCommand(pane: handle, direction: daemonDirection,
                                       options: SpawnOptions(cwd: cwd, workspace: workspace, keep: keep), swapTowards: swapTowards)
        // Cmd+D on a daemon with client keys: the new pane shows and takes focus in this frame
        // (plans/cmux-next/remote-state-ownership.md S3); otherwise after the reply.
        let provisional = command.isOptimistic(on: daemon) ? ProvisionalPane() : nil
        if let provisional { content?.focus.expect(.tab(provisional.tabID), generation: intent) } // its id is stable through the confirm; its surface is not
        // The window's keys wait until the new pane has the keyboard (cx-wb5.76): on the old path
        // focus moves only after the reply; on the optimistic path the provisional view stays (it
        // attaches when the daemon confirms) and takes keys by terminal id at once (cx-wb5.78).
        let window = content == nil ? nil : controller?.view.window
        let keys = ctx.services.keyRouter.creationInputCoordinator.begin(in: window, generation: intent, earlyTab: daemon.queuesCreatingInput ? provisional?.tabID : nil, tab: provisional?.tabID)
        // The provisional pane is in the store now, and the window lays it out and mounts it in this
        // turn, so it draws in the key's frame (instant-new-surfaces), not after a main-actor hop.
        // The split and the even sizing of its chain are one gesture: hold the chain's target
        // before waiting for the daemon even on the compatibility path. Optimistic splits also
        // show their provisional pane in this frame; older daemons cannot show that pane until
        // the reply, but their existing chain must not wait for a second sizing phase. The ratio
        // intents go once the daemon made the split.
        let shownSizing = content?.layoutModel.showSplitSizing(sizing)
        if provisional == nil { content?.layoutView.syncWithModel() }
        // The new pane's grid, read once the window laid it out: the daemon then starts its shell
        // on the prewarmed host at that size, so the prompt shows sooner (like Cmd-T's tab).
        let chrome = controller?.contentChrome
        let intended = provisional.map { provisional in
            defer { BenchSpans.measure("split.layout") { content?.applyCurrent() } }
            let laidOutSize: @MainActor () -> CellSize? = {
                guard let controller, let chrome, let newPane = content?.handles.paneIDs[provisional.handle] else { return nil }
                return controller.splitTerminalSize(newPane: newPane, chrome: chrome)
            }
            return BenchSpans.measure("split.intend") { command.intendNow(on: daemon, provisional: provisional, laidOutSize: laidOutSize) }
        }
        ctx.registry.track(Task {
            var landed = false
            defer { ctx.services.keyRouter.creationInputCoordinator.resolve(keys, landed: landed, in: window) }
            do {
                let created = if let intended {
                    try await intended()
                } else {
                    try await command.send(on: daemon)
                }
                BenchSpans.mark(provisional == nil ? "split.reply" : "split.reply.optimistic")
                if provisional == nil { content?.expectFocus(on: created.surface, generation: intent) }
                landed = true
                if let shownSizing { content?.layoutModel.commitSplitSizing(shownSizing) }
                return nil
            } catch {
                if let shownSizing { content?.layoutModel.cancelSplitSizing(shownSizing) }
                logger.error("split failed: \(String(describing: error), privacy: .public)")
                return "split: \(error)"
            }
        })
    }

    static func edge(_ direction: PaneDirection) -> PaneEdge {
        switch direction {
        case .left: .left
        case .right: .right
        case .up: .top
        case .down: .bottom
        }
    }

    // MARK: Focus

    private static func bindFocus(_ registry: ActionRegistry, _ ctx: AppActionContext) {
        let directions: [(ActionID, LayoutDirection)] = [("focusLeft", .left), ("focusRight", .right), ("focusUp", .up), ("focusDown", .down)]
        for (id, direction) in directions {
            registry.bind(id, invoke: { invocation in
                guard let pane = ctx.paneController(invocation), let content = pane.workspace else { return }
                guard let next = neighbor(of: pane.layoutPaneID, direction: direction, in: content) else {
                    return ctx.refuseQuietly(RefusalStrings.noPaneInDirection(RefusalStrings.direction(direction)))
                }
                focusByKey(next, in: content)
            })
        }
        registry.bind("focusPreviousPane", invoke: { cycleFocus(ctx, $0, offset: -1) })
        registry.bind("focusNextPane", invoke: { cycleFocus(ctx, $0, offset: 1) })
        registry.bind("focusPaneByNumber", invoke: { invocation in
            guard let pane = ctx.paneController(invocation), let content = pane.workspace,
                  let screen = content.layoutModel.screen(containing: pane.layoutPaneID) else { return }
            guard let number = invocation["index"]?.intValue ?? ctx.refuse(RefusalStrings.indexRequired) else { return }
            // Focus Next Pane's order; 9 is always the last pane, as Cmd-9 is the last workspace.
            let order = screen.layout.visualPanes
            let index = number >= 9 ? order.count - 1 : number - 1
            guard order.indices.contains(index) else { return ctx.refuseQuietly(RefusalStrings.noPaneWithNumber) }
            focusByKey(order[index], in: content)
        })
    }

    private static func cycleFocus(_ ctx: AppActionContext, _ invocation: ActionInvocation, offset: Int) {
        guard let pane = ctx.paneController(invocation), let content = pane.workspace,
              let screen = content.layoutModel.screen(containing: pane.layoutPaneID) else { return }
        let order = screen.layout.visualPanes
        guard order.count > 1, let index = order.firstIndex(of: pane.layoutPaneID) else {
            return ctx.refuseQuietly(RefusalStrings.screenHasOnePane)
        }
        focusByKey(order[(index + offset + order.count) % order.count], in: content)
    }

    // MARK: Sizing

    private static func bindSizing(_ registry: ActionRegistry, _ ctx: AppActionContext) {
        let resizes: [(ActionID, LayoutDirection)] = [
            ("resizePaneLeft", .left), ("resizePaneRight", .right), ("resizePaneUp", .up), ("resizePaneDown", .down),
        ]
        for (id, direction) in resizes {
            registry.bind(id, invoke: { invocation in
                guard let pane = ctx.paneController(invocation), let content = pane.workspace,
                      let screen = content.layoutModel.screen(containing: pane.layoutPaneID) else { return }
                switch PaneResize.change(for: pane.layoutPaneID, direction: direction, in: screen.layout) {
                case .splitRatio(let split, let ratio):
                    content.layoutModel.setSplitRatio(split, ratio: ratio, transaction: .make(), phase: .ended)
                case .columnWidth(let column, let width):
                    content.layoutModel.setColumnWidth(column, width: width, transaction: .make(), phase: .ended)
                case nil:
                    ctx.refuseQuietly(RefusalStrings.noDividerToMove(RefusalStrings.direction(direction)))
                }
            })
        }
        registry.bind("equalizeSplits", invoke: { invocation in
            guard let content = ctx.content(invocation), let screen = content.layoutModel.activeScreen else { return }
            let trees: [SplitNode] = switch screen.layout {
            case .splits(let root): [root]
            case .columns(let columns): columns.flatMap(\.trees)
            }
            let splits = trees.flatMap(\.splits)
            guard !splits.isEmpty else { return ctx.refuseQuietly(RefusalStrings.screenHasNoSplits) }
            for split in splits { content.layoutModel.equalizeSplit(split) }
        })
        registry.bind("toggleSplitZoom", invoke: { invocation in
            guard let pane = ctx.daemonPane(invocation) else { return }
            let handle = pane.handle
            ctx.send("zoom-pane") { _ = try await $0.zoomPane(handle) }
        })
    }
}
