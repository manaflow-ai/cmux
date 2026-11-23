import CmuxNextActions
import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextLayout
import CmuxNextWindowRules

/// scrolling-column column actions: new column, focus and move left/right, center,
/// width presets. Widths go through the layout model (one gesture transaction per
/// change, settled by the daemon); moves are `move-column`, which moves the
/// whole column (every pane in it) in one daemon commit.
enum ColumnHandlers {
    static func bind(into registry: ActionRegistry, context ctx: AppActionContext) {
        registry.bind("newColumn", invoke: { invocation in
            guard let pane = ctx.paneController(invocation), let content = pane.workspace else { return }
            content.layoutModel.newColumn(after: pane.layoutPaneID)
        })
        // New Column Left: disabled, with the reason, on a daemon without `column-left-v1`.
        // The column shows in the key's turn (an optimistic intent, WorkspaceContentController.newColumn).
        registry.bindEffect("newColumnLeft", unavailable: { newColumnLeftUnavailableReason(ctx) }, effect: { invocation in
            guard let pane = ctx.paneController(invocation), let content = pane.workspace else { return .done }
            content.layoutModel.newColumn(before: pane.layoutPaneID)
            return .done
        })
        // New Row (plans/cmux-next/rows.md): disabled while rows are off (O2)
        // or the daemon lacks rows-v1; the layout model checks both again.
        registry.bind("newRow", unavailable: { newRowUnavailableReason(ctx) }, invoke: { invocation in
            guard let pane = ctx.paneController(invocation), let content = pane.workspace else { return }
            if !content.layoutModel.newRow(below: pane.layoutPaneID) {
                ctx.refuse(newRowUnavailableReason(ctx) ?? RefusalStrings.needsDaemonCapability(DaemonCapability.rows.rawValue))
            }
        })
        // Focus, move, center and widths: Rust plans them over the column found here (cmux-window-rules
        // `chat::column_plan`, whose table names the ids).
        for id in WindowRules().columnActions()?.planned ?? [] {
            registry.bind(ActionID(rawValue: id), invoke: { run(id, $0, ctx) })
        }
    }

    /// Why New Row cannot run now: rows off, or a daemon without rows-v1.
    @MainActor static func newRowUnavailableReason(_ ctx: AppActionContext) -> String? {
        guard ctx.design.layoutRows else { return RefusalStrings.rowsTurnedOff }
        let daemon = ctx.services.activeDaemon
        guard !daemon.supports(DaemonCapability.rows.rawValue) else { return nil }
        return daemon.missingCapabilityMessage(DaemonCapability.rows.rawValue)
    }

    /// Why New Column Left cannot run now: a daemon without `column-left-v1`.
    @MainActor static func newColumnLeftUnavailableReason(_ ctx: AppActionContext) -> String? {
        let daemon = ctx.services.activeDaemon
        guard !daemon.supports(DaemonCapability.columnLeft.rawValue) else { return nil }
        return daemon.missingCapabilityMessage(DaemonCapability.columnLeft.rawValue)
    }

    /// The targeted column (`column:<id>`), else the targeted or focused
    /// pane's column (a split screen's implicit column).
    static func column(_ invocation: ActionInvocation, _ ctx: AppActionContext) -> (WorkspaceContentController, LayoutColumn)? {
        target(invocation, ctx).map { ($0.0, $0.2) }
    }

    /// The one column resolver of the column actions and their availability, with the column's screen and workspace.
    /// `refusing` (a run): a column or pane named and not shown is refused; availability never refuses and finds a
    /// targeted pane by its key.
    static func target(_ invocation: ActionInvocation, _ ctx: AppActionContext, refusing: Bool = true)
        -> (WorkspaceContentController, LayoutScreen, LayoutColumn)? {
        let contents = ctx.services.windows.controllers.compactMap(\.content)
        if let target = invocation.target, target.kind == .column {
            for content in contents {
                for screen in content.layoutModel.screens {
                    if let column = screen.column(id: CmuxNextLayout.ColumnID(target.id)) { return (content, screen, column) }
                }
            }
            return refusing ? ctx.refuse(RefusalStrings.noColumnShown(target.id)) : nil
        }
        let named: PaneController?? = invocation.target.map { target in contents.lazy.compactMap { $0.panes.values.first { pane in
            target.kind == .pane ? pane.paneKey == target.id : pane.stripModel.tab(StripTabID(target.id)) != nil
        } }.first } // .some(nil): a pane or tab named and not found has no column, never the focused pane's
        let pane = refusing ? ctx.paneController(invocation) : named ?? ctx.services.windows.active?.focusedPane
        guard let pane, let content = pane.workspace, let screen = content.layoutModel.screen(containing: pane.layoutPaneID),
              let column = screen.column(containing: pane.layoutPaneID) else { return nil }
        return (content, screen, column)
    }

    /// `column` of `screen` as the column rules read it.
    static func facts(_ column: LayoutColumn, of screen: LayoutScreen) -> WindowRules.ActionColumn {
        WindowRules.ActionColumn(width: column.width, panes: column.root.panes.map(\.rawValue),
                                 implicit: column.id == screen.implicitColumnID, docked: column.dock != nil)
    }

    /// Runs column action `id`: Rust's plan over the column's facts, then the layout model or daemon command.
    private static func run(_ id: String, _ invocation: ActionInvocation, _ ctx: AppActionContext) {
        guard let (content, screen, column) = target(invocation, ctx) else { return }
        let anchor = column.root.panes.first
        let adjacent = { (forward: Bool) in
            anchor.flatMap { PaneResize.adjacentColumn(of: $0, forward: forward, in: screen.layout) }?.root.panes.map(\.rawValue)
        }
        let daemon = ctx.services.activeDaemon
        let known = WindowRules.ColumnFacts(
            column: Self.facts(column, of: screen), left: adjacent(false), right: adjacent(true),
            recent: content.recentPanes.map(\.rawValue), focused: content.layoutModel.focusedPane?.rawValue,
            columnMove: daemon.supports(DaemonCapability.columnMove.rawValue), handle: anchor.flatMap { content.handles.panes[$0] } != nil)
        guard let plan = WindowRules().columnPlan(id, known) else { return }
        switch plan {
        case .setWidth(let width):
            content.layoutModel.setColumnWidth(column.id, width: width, transaction: .make(), phase: .ended)
        case .moveColumn(let right, let pane):
            guard let handle = content.handles.panes[LayoutPaneID(rawValue: pane)] else { return }
            ctx.send("move-column") { try await $0.moveColumn(of: handle, direction: right ? ColumnMoveDirection.right : .left) }
        case .swapPane(let right, let pane):
            guard let handle = content.handles.panes[LayoutPaneID(rawValue: pane)] else { return }
            ctx.send("swap-pane") { try await $0.swapPane(handle, with: .direction(right ? PaneDirection.right : .left)) }
        case .focus(let pane):
            PaneHandlers.focusByKey(LayoutPaneID(rawValue: pane), in: content, invocation)
        case .center(let pane):
            content.layoutModel.centerColumn(containing: LayoutPaneID(rawValue: pane))
        case .refuse(let refusal, let quiet):
            let reason = switch refusal {
            case .alreadyHasWidth: RefusalStrings.columnAlreadyHasWidth
            case .columnAtEdge: RefusalStrings.columnAtEdge
            case .noColumnInDirection(let right): RefusalStrings.noColumnInDirection(RefusalStrings.direction(right ? .right : .left))
            case .needsColumnMove: daemon.missingCapabilityMessage(DaemonCapability.columnMove.rawValue)
            case .noHandle: RefusalStrings.paneHasNoDaemonHandle(anchor?.rawValue ?? "")
            }
            if quiet { ctx.refuseQuietly(reason) } else { ctx.refuse(reason) }
        case .nothing:
            return
        }
    }
}
