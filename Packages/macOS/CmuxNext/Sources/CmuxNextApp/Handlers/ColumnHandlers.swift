import CmuxNextActions
import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextLayout

/// niri-style column actions: new column, focus and move left/right, center,
/// width presets. Widths go through the layout model (one gesture transaction per
/// change, settled by the daemon); moves are `swap-pane`, which the daemon
/// offers only per pane, so a multi-pane column cannot move yet.
enum ColumnHandlers {
    static func bind(into registry: ActionRegistry, context ctx: AppActionContext) {
        registry.bind("newColumn", invoke: { invocation in
            guard let pane = ctx.paneController(invocation), let content = pane.workspace else { return }
            content.handle(.newColumn(after: pane.layoutPaneID, width: ColumnWidthPreset.defaultWidth))
        })
        registry.bind("column.focusLeft", invoke: { focusAdjacent($0, forward: false, ctx) })
        registry.bind("column.focusRight", invoke: { focusAdjacent($0, forward: true, ctx) })
        registry.bind("column.moveLeft", invoke: { move($0, direction: .left, ctx) })
        registry.bind("column.moveRight", invoke: { move($0, direction: .right, ctx) })
        registry.bind("column.center", invoke: { invocation in
            guard let (content, column) = column(invocation, ctx), let pane = column.root.panes.first else { return }
            let focused = content.layoutModel.focusedPane.flatMap { column.root.contains($0) ? $0 : nil }
            content.layoutModel.centerColumn(containing: focused ?? pane)
        })
        let presets: [(ActionID, ColumnWidthPreset)] = [
            ("column.widthOneThird", .oneThird), ("column.widthHalf", .half),
            ("column.widthTwoThirds", .twoThirds), ("column.widthFull", .full),
        ]
        for (id, preset) in presets {
            registry.bind(id, invoke: { invocation in
                guard let (content, column) = column(invocation, ctx) else { return }
                setWidth(preset.rawValue, of: column, in: content, ctx)
            })
        }
        registry.bind("column.cycleWidth", invoke: { cycle($0, forward: true, ctx) })
        registry.bind("column.cycleWidthBack", invoke: { cycle($0, forward: false, ctx) })
    }

    /// The targeted column (`column:<id>`), else the targeted or focused
    /// pane's column. Refuses outside columns mode.
    private static func column(_ invocation: ActionInvocation, _ ctx: AppActionContext) -> (WorkspaceContentController, LayoutColumn)? {
        if let target = invocation.target, target.kind == .column {
            for window in ctx.services.windows.controllers {
                guard let content = window.content else { continue }
                for screen in content.layoutModel.screens {
                    if let column = screen.layout.columns.first(where: { $0.id.rawValue == target.id }) { return (content, column) }
                }
            }
            return ctx.refuse("no column \(target.id) is shown")
        }
        guard let pane = ctx.paneController(invocation), let content = pane.workspace else { return nil }
        guard let column = content.layoutModel.screen(containing: pane.layoutPaneID)?.layout.column(containing: pane.layoutPaneID)
            ?? ctx.refuse("the screen is not in column layout") else { return nil }
        return (content, column)
    }

    private static func setWidth(_ width: Double, of column: LayoutColumn, in content: WorkspaceContentController, _ ctx: AppActionContext) {
        guard abs(column.width - width) > 0.001 else { return ctx.refuse("the column already has that width") }
        content.layoutModel.setColumnWidth(column.id, width: width, transaction: .make(), phase: .ended)
    }

    private static func cycle(_ invocation: ActionInvocation, forward: Bool, _ ctx: AppActionContext) {
        guard let (content, column) = column(invocation, ctx) else { return }
        setWidth(ColumnWidthPreset.next(after: column.width, forward: forward).rawValue, of: column, in: content, ctx)
    }

    private static func focusAdjacent(_ invocation: ActionInvocation, forward: Bool, _ ctx: AppActionContext) {
        guard let (content, column) = column(invocation, ctx), let anchor = column.root.panes.first,
              let screen = content.layoutModel.screen(containing: anchor) else { return }
        guard let next = PaneResize.adjacentColumn(of: anchor, forward: forward, in: screen.layout),
              let pane = next.root.panes.first else {
            return ctx.refuse("no column to the \(forward ? "right" : "left")")
        }
        PaneHandlers.focus(pane, in: content)
    }

    private static func move(_ invocation: ActionInvocation, direction: PaneDirection, _ ctx: AppActionContext) {
        guard let (content, column) = column(invocation, ctx) else { return }
        let panes = column.root.panes
        guard panes.count == 1, let pane = panes.first else {
            return ctx.refuse("needs daemon capability move-column (the column has \(panes.count) panes; swap-pane moves one)")
        }
        guard let screen = content.layoutModel.screen(containing: pane),
              PaneResize.adjacentColumn(of: pane, forward: direction == .right, in: screen.layout) != nil else {
            return ctx.refuse("the column is already at the edge")
        }
        guard let handle = content.handles.panes[pane] ?? ctx.refuse("pane \(pane.rawValue) has no daemon handle") else { return }
        ctx.send("swap-pane") { try await $0.swapPane(handle, with: .direction(direction)) }
    }
}
