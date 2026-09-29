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

    /// The pane next to `pane` in `direction` on its screen, by displayed frames.
    static func neighbor(of pane: LayoutPaneID, direction: LayoutDirection, in content: WorkspaceContentController) -> LayoutPaneID? {
        guard let screen = content.layoutModel.screen(containing: pane) else { return nil }
        var frames: [LayoutPaneID: CGRect] = [:]
        for id in screen.layout.panes {
            if let frame = content.layoutView.frame(of: id) { frames[id] = frame }
        }
        return FocusNavigation.neighbor(of: pane, direction: direction, frames: frames)
    }

    static func focus(_ pane: LayoutPaneID, in content: WorkspaceContentController) {
        content.layoutModel.focus(pane)
        content.panes[pane]?.focusContent()
    }

    // MARK: Splits

    private static func bindSplits(_ registry: ActionRegistry, _ ctx: AppActionContext) {
        let splits: [(ActionID, PaneDirection)] = [("splitRight", .right), ("splitDown", .down), ("splitLeft", .left), ("splitUp", .up)]
        for (id, direction) in splits {
            registry.bind(id, invoke: { split(ctx, $0, direction: direction) })
        }
        registry.bind("newPaneAutoLayout", invoke: { invocation in
            guard let pane = ctx.paneController(invocation), let content = pane.workspace else { return }
            let frame = content.layoutView.frame(of: pane.layoutPaneID) ?? .zero
            split(ctx, invocation, direction: frame.width >= frame.height ? .right : .down)
        })
    }

    /// Splits the targeted pane (a shown one or any daemon pane, so the CLI
    /// can split a background workspace). Left and up split right or down,
    /// then swap the original into the new slot, so the new pane lands on
    /// that side. A shown workspace focuses the new pane.
    static func split(_ ctx: AppActionContext, _ invocation: ActionInvocation, direction: PaneDirection) {
        guard let pane = ctx.daemonPane(invocation), let connection = ctx.connection() else { return }
        let controller = ctx.services.paneController(for: pane)
        let content = controller?.workspace
        let handle = pane.handle
        let cwd = invocation["cwd"]?.stringValue ?? controller?.selectedTab?.cwd ?? pane.tabs.first?.cwd
        let workspace = ctx.services.workspaceKey(of: pane)
        let daemonDirection: SplitDirection = direction == .left || direction == .right ? .right : .down
        let swapTowards: PaneDirection? = switch direction {
        case .left: .right
        case .up: .down
        default: nil
        }
        let logger = ctx.services.daemon.logger
        ctx.registry.track(Task {
            do {
                let created = try await connection.split(handle, direction: daemonDirection, options: SpawnOptions(cwd: cwd, workspace: workspace))
                if let swapTowards { try await connection.swapPane(handle, with: .direction(swapTowards)) }
                content?.pendingFocusSurface = created.surface
                content?.applyCurrent()
                return nil
            } catch {
                logger.error("split failed: \(String(describing: error), privacy: .public)")
                return "split: \(error)"
            }
        })
    }

    // MARK: Focus

    private static func bindFocus(_ registry: ActionRegistry, _ ctx: AppActionContext) {
        let directions: [(ActionID, LayoutDirection)] = [("focusLeft", .left), ("focusRight", .right), ("focusUp", .up), ("focusDown", .down)]
        for (id, direction) in directions {
            registry.bind(id, invoke: { invocation in
                guard let pane = ctx.paneController(invocation), let content = pane.workspace else { return }
                guard let next = neighbor(of: pane.layoutPaneID, direction: direction, in: content) else {
                    return ctx.refuse(RefusalStrings.noPaneInDirection(RefusalStrings.direction(direction)))
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
            return ctx.refuse(RefusalStrings.screenHasOnePane)
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
                    ctx.refuse(RefusalStrings.noDividerToMove(RefusalStrings.direction(direction)))
                }
            })
        }
        registry.bind("equalizeSplits", invoke: { invocation in
            guard let content = ctx.content(invocation), let screen = content.layoutModel.activeScreen else { return }
            let trees: [SplitNode] = switch screen.layout {
            case .splits(let root): [root]
            case .columns(let columns): columns.map(\.root)
            }
            let splits = trees.flatMap(\.splits)
            guard !splits.isEmpty else { return ctx.refuse(RefusalStrings.screenHasNoSplits) }
            for split in splits { content.layoutModel.equalizeSplit(split) }
        })
        registry.bind("toggleSplitZoom", invoke: { invocation in
            guard let pane = ctx.daemonPane(invocation) else { return }
            let handle = pane.handle
            ctx.send("zoom-pane") { _ = try await $0.zoomPane(handle) }
        })
    }
}
