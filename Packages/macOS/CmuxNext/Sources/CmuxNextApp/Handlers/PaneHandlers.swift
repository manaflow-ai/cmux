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
        let cwd = invocation["cwd"]?.stringValue ?? controller?.selectedTab?.cwd ?? pane.tabs.first?.cwd
        let workspace = ctx.services.workspaceKey(of: pane)
        let keep = invocation["keep"]?.boolValue == true ? true : nil
        let logger = ctx.services.daemon.logger
        // The one tool-split rule (AppServices.toolSplit, cx-yihq): never a new column; from the
        // docked chat, a person's terminal opens as a tab in the strip (its cwd the explicit one or
        // the daemon's resolver, NEW-TERMINAL-INHERITS-CWD).
        switch ctx.services.toolSplit(from: pane, edge: edge(direction), byPerson: invocation.origin == .user) {
        case .split:
            break
        case .refused(let reason):
            return ctx.refuse(reason)
        case .tab(let strip):
            if let content = strip.workspace { focus(strip.layoutPaneID, in: content) }
            return strip.newTerminalTab(cwd: invocation["cwd"]?.stringValue, keep: keep, fromSelectedTab: true, daemonResolvesCwd: true)
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
        if let provisional { content?.expectFocus(on: provisional.surface, generation: intent) }
        // The window's keys wait until the new pane has the keyboard (cx-wb5.76): on the old path
        // focus moves only after the reply, and on the optimistic path the swap to the daemon's
        // pane remounts the view; keys typed in either gap went to the old pane.
        let window = content == nil ? nil : controller?.view.window
        let keys = ctx.services.keyRouter.creationInputCoordinator.begin(in: window, generation: intent)
        ctx.registry.track(Task {
            var landed = false
            defer { ctx.services.keyRouter.creationInputCoordinator.resolve(keys, landed: landed, in: window) }
            do {
                let created = if let provisional {
                    try await command.sendIntended(on: daemon, provisional: provisional)
                } else {
                    try await command.send(on: daemon)
                }
                content?.expectFocus(on: created.surface, generation: intent)
                landed = true
                content?.layoutModel.applySplitSizing(sizing)
                return nil
            } catch {
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
                focus(next, in: content)
            })
        }
        registry.bind("focusPreviousPane", invoke: { cycleFocus(ctx, $0, offset: -1) })
        registry.bind("focusNextPane", invoke: { cycleFocus(ctx, $0, offset: 1) })
    }

    private static func cycleFocus(_ ctx: AppActionContext, _ invocation: ActionInvocation, offset: Int) {
        guard let pane = ctx.paneController(invocation), let content = pane.workspace,
              let screen = content.layoutModel.screen(containing: pane.layoutPaneID) else { return }
        let order = screen.layout.panes
        guard order.count > 1, let index = order.firstIndex(of: pane.layoutPaneID) else {
            return ctx.refuseQuietly(RefusalStrings.screenHasOnePane)
        }
        focus(order[(index + offset + order.count) % order.count], in: content)
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
