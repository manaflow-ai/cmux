import CmuxNextActions
import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextLayout

/// scrolling-column column actions: new column, focus and move left/right, center,
/// width presets. Widths go through the layout model (one gesture transaction per
/// change, settled by the daemon); moves are `swap-pane`, which the daemon
/// offers only per pane, so a multi-pane column cannot move yet.
enum ColumnHandlers {
    static func bind(into registry: ActionRegistry, context ctx: AppActionContext) {
        registry.bind("newColumn", invoke: { invocation in
            guard let pane = ctx.paneController(invocation), let content = pane.workspace else { return }
            content.layoutModel.newColumn(after: pane.layoutPaneID)
        })
        // New Row (plans/cmux-next/rows.md): disabled while rows are off (O2)
        // or the daemon lacks rows-v1; the layout model checks both again.
        registry.bind("newRow", unavailable: { newRowUnavailableReason(ctx) }, invoke: { invocation in
            guard let pane = ctx.paneController(invocation), let content = pane.workspace else { return }
            if !content.layoutModel.newRow(below: pane.layoutPaneID) {
                ctx.refuse(newRowUnavailableReason(ctx) ?? RefusalStrings.needsDaemonCapability(DaemonCapabilities.shared.rows))
            }
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

    /// Why New Row cannot run now: rows off, or a daemon without rows-v1.
    @MainActor static func newRowUnavailableReason(_ ctx: AppActionContext) -> String? {
        guard ctx.design.layoutRows else { return RefusalStrings.rowsTurnedOff }
        let daemon = ctx.services.activeDaemon
        guard !daemon.supports(DaemonCapabilities.shared.rows) else { return nil }
        return daemon.missingCapabilityMessage(DaemonCapabilities.shared.rows)
    }

    /// The targeted column (`column:<id>`), else the targeted or focused
    /// pane's column (a split screen's implicit column).
    static func column(_ invocation: ActionInvocation, _ ctx: AppActionContext) -> (WorkspaceContentController, LayoutColumn)? {
        if let target = invocation.target, target.kind == .column {
            for window in ctx.services.windows.controllers {
                guard let content = window.content else { continue }
                for screen in content.layoutModel.screens {
                    if let column = screen.column(id: CmuxNextLayout.ColumnID(target.id)) { return (content, column) }
                }
            }
            return ctx.refuse(RefusalStrings.noColumnShown(target.id))
        }
        guard let pane = ctx.paneController(invocation), let content = pane.workspace else { return nil }
        // Every screen is a column strip; a screen stored as one split tree
        // is its implicit column.
        guard let column = content.layoutModel.screen(containing: pane.layoutPaneID)?.column(containing: pane.layoutPaneID)
        else { return nil }
        return (content, column)
    }

    private static func setWidth(_ width: Double, of column: LayoutColumn, in content: WorkspaceContentController, _ ctx: AppActionContext) {
        guard abs(column.width - width) > 0.001 else { return ctx.refuseQuietly(RefusalStrings.columnAlreadyHasWidth) }
        content.layoutModel.setColumnWidth(column.id, width: width, transaction: .make(), phase: .ended)
    }

    private static func cycle(_ invocation: ActionInvocation, forward: Bool, _ ctx: AppActionContext) {
        guard let (content, column) = column(invocation, ctx) else { return }
        setWidth(ColumnWidthPreset.next(after: column.width, forward: forward).rawValue, of: column, in: content, ctx)
    }

    private static func focusAdjacent(_ invocation: ActionInvocation, forward: Bool, _ ctx: AppActionContext) {
        guard let (content, column) = column(invocation, ctx), let anchor = column.root.panes.first,
              let screen = content.layoutModel.screen(containing: anchor) else { return }
        // The column's active (most recently focused) tile, else its first.
        guard let next = PaneResize.adjacentColumn(of: anchor, forward: forward, in: screen.layout),
              let pane = FocusNavigation.mostRecent(next.root.panes, recency: content.recentPanes) ?? next.root.panes.first else {
            return ctx.refuseQuietly(RefusalStrings.noColumnInDirection(RefusalStrings.direction(forward ? .right : .left)))
        }
        PaneHandlers.focus(pane, in: content)
    }

    private static func move(_ invocation: ActionInvocation, direction: PaneDirection, _ ctx: AppActionContext) {
        guard let (content, column) = column(invocation, ctx) else { return }
        let panes = column.root.panes
        guard panes.count == 1, let pane = panes.first else {
            return ctx.refuse(RefusalStrings.moveColumnUnsupported("move-column", panes.count))
        }
        guard let screen = content.layoutModel.screen(containing: pane),
              PaneResize.adjacentColumn(of: pane, forward: direction == .right, in: screen.layout) != nil else {
            return ctx.refuseQuietly(RefusalStrings.columnAtEdge)
        }
        guard let handle = content.handles.panes[pane] ?? ctx.refuse(RefusalStrings.paneHasNoDaemonHandle(pane.rawValue)) else { return }
        ctx.send("swap-pane") { try await $0.swapPane(handle, with: .direction(direction)) }
    }
}
