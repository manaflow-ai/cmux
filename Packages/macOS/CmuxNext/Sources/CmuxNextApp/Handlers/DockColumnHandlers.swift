import CmuxNextActions
import CmuxNextDaemon
import CmuxNextLayout

/// Dock Column, Dock Column Left/Right/Top/Bottom, Float Column and Undock
/// Column (plans/cmux-next/layout-model.md). With no arguments a dock uses
/// cmux.json `layout.dockColumnEdge` and `layout.dockColumnMode` when
/// set; unset, it is docked (not floating), on the edge the column is
/// nearer to, at its width clamped to 25-40% (`DockDefaults`). Running the
/// same action again undocks. A screen's only scrolling column must keep
/// scrolling, so there the focused tab moves into a new docked column; when
/// it is the pane's only tab, a fresh tab of the same kind (a terminal in
/// the same directory) stays behind (`tab-column-respawn-v1`).
enum DockColumnHandlers {
    static func bind(into registry: ActionRegistry, context ctx: AppActionContext) {
        let capability = DaemonCapabilities.shared.dockColumns
        let daemon = ctx.services.activeDaemon
        registry.bind("column.dock", requires: capability, daemon: daemon, run: { invocation in
            let edge = invocation["edge"]?.stringValue.flatMap(DockEdge.init(rawValue:))
            let mode = invocation["mode"]?.stringValue.flatMap(DockMode.init(rawValue:)) ?? ColumnDocking.defaultMode
            try dock(invocation, edge: edge, mode: mode, ctx)
        })
        let sides: [(ActionID, DockEdge)] = [("column.dockLeft", .left), ("column.dockRight", .right),
                                               ("column.dockTop", .top), ("column.dockBottom", .bottom)]
        for (id, edge) in sides {
            registry.bind(id, requires: capability, daemon: daemon, run: { invocation in
                try dock(invocation, edge: edge, mode: ColumnDocking.defaultMode, ctx)
            })
        }
        registry.bind("column.float", requires: capability, daemon: daemon, run: { invocation in
            try dock(invocation, edge: nil, mode: .overlay, ctx)
        })
        registry.bind("column.undock", requires: capability, daemon: daemon, run: { invocation in
            guard let (content, column) = ColumnHandlers.column(invocation, ctx) else { return }
            try ColumnDocking.apply(nil, to: column, in: content)
        })
    }

    /// Plans the dock for the invocation's column and performs it.
    static func dock(_ invocation: ActionInvocation, edge: DockEdge?, mode: DockMode, _ ctx: AppActionContext) throws {
        guard let (content, column) = ColumnHandlers.column(invocation, ctx) else { return }
        guard let screen = content.layoutModel.screens.first(where: { $0.column(id: column.id) != nil }) else {
            throw ActionFailure.invalidTarget(RefusalStrings.noColumnShown(column.id.rawValue))
        }
        let focused = content.layoutModel.focusedPane
        guard let plan = DockDefaults().plan(screen: screen, column: column.id, pane: focused, edge: edge,
                                           defaultEdge: ColumnDocking.configuredEdge, mode: mode) else {
            throw ActionFailure.invalidTarget(RefusalStrings.noColumnShown(column.id.rawValue))
        }
        try perform(plan, column: column, in: content, ctx)
    }

    static func perform(_ plan: DockPlan, column: LayoutColumn, in content: WorkspaceContentController, _ ctx: AppActionContext) throws {
        switch plan {
        case .undock:
            try ColumnDocking.apply(nil, to: column, in: content)
        case .pin(_, let dock, let width):
            // Width and pin in one transaction: one undo step.
            let transaction = LayoutTransactionID.make()
            if dock.edge.isBand, !content.daemon.supports(DaemonCapabilities.shared.edgeDocks) {
                throw ActionFailure(message: content.daemon.missingCapabilityMessage(DaemonCapabilities.shared.edgeDocks))
            }
            if abs(column.width - width) > 0.001 {
                content.layoutModel.setColumnWidth(column.id, width: width, transaction: transaction, phase: .ended)
            }
            try ColumnDocking.apply(dock, to: column, in: content, transaction: transaction)
        case .moveTab(let pane, let dock, let width):
            let docks = DaemonCapabilities.shared.edgeDocks
            guard content.daemon.supports(docks) else { throw ActionFailure(message: content.daemon.missingCapabilityMessage(docks)) }
            guard let controller = content.panes[pane], let tab = controller.selectedTab else {
                throw ActionFailure.invalidTarget(RefusalStrings.focusedPaneHasNoTab)
            }
            // The column keeps a tab to scroll: the pane keeps another tab,
            // the column keeps another pane, or a fresh tab stays behind.
            var respawn: SplitRespawn?
            if controller.pane.tabs.count == 1, column.root.panes.count == 1 {
                let capability = DaemonCapabilities.shared.tabColumnRespawn
                guard content.daemon.supports(capability) else {
                    throw ActionFailure(message: content.daemon.missingCapabilityMessage(capability))
                }
                respawn = TabMoves.respawn(for: tab, in: controller.pane, services: ctx.services)
                guard respawn != nil else { throw ActionFailure.invalidTarget(RefusalStrings.openSecondTabToDock) }
            }
            let reveal = TabHandlers.revealer(ctx, tab: tab, outcome: .newColumn(screenID: "", afterColumnID: ""), workspaceID: nil)
            TabMoves.toNewDockColumn(tab, anchor: controller.pane, edge: dock.edge, mode: dock.mode, width: width,
                                       respawn: respawn, services: ctx.services, completion: reveal)
        }
    }
}
