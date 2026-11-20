import CmuxNextActions
import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextDaemonService
import CmuxNextLayout
import CmuxNextWindowRules

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
        let capability = DaemonCapability.dockColumns.rawValue
        registry.bind("column.dock", requires: capability, daemon: ctx.services.activeDaemon, run: { invocation in
            let edge = invocation["edge"]?.stringValue.flatMap(DockEdge.init(rawValue:))
            let mode = invocation["mode"]?.stringValue.flatMap(DockMode.init(rawValue:)) ?? ColumnDocking.defaultMode
            try dock(invocation, edge: edge, mode: mode, ctx)
        })
        let sides: [(ActionID, DockEdge)] = [("column.dockLeft", .left), ("column.dockRight", .right),
                                               ("column.dockTop", .top), ("column.dockBottom", .bottom)]
        for (id, edge) in sides {
            registry.bind(id, requires: capability, daemon: ctx.services.activeDaemon, run: { invocation in
                try dock(invocation, edge: edge, mode: ColumnDocking.defaultMode, ctx)
            })
        }
        registry.bind("column.float", requires: capability, daemon: ctx.services.activeDaemon, run: { invocation in
            try dock(invocation, edge: nil, mode: .overlay, ctx)
        })
        WindowDockActions(host: ctx.services).bind(into: registry)
        registry.bind("column.undock", requires: capability, daemon: ctx.services.activeDaemon, run: { invocation in
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
            let daemon = content.daemon
            if let needs = WindowRules().dockNeeds(band: dock.edge.isBand, dockColumns: true,
                                                   edgeDocks: daemon.supports(DaemonCapability.edgeDocks.rawValue)) {
                throw ActionFailure(message: daemon.missingCapabilityMessage(needs))
            }
            if abs(column.width - width) > 0.001 {
                content.layoutModel.setColumnWidth(column.id, width: width, transaction: transaction, phase: .ended)
            }
            try ColumnDocking.apply(dock, to: column, in: content, transaction: transaction)
        case .moveTab(let pane, let dock, let width):
            // The column keeps a tab to scroll: the pane keeps another tab, the column keeps another
            // pane, or a fresh tab stays behind; the anchor places the new column (`chat::dock_move`).
            let daemon = content.daemon, controller = content.panes[pane], tab = controller?.selectedTab
            let facts = WindowRules.DockMoveFacts(
                pane: pane.rawValue, paneTabs: controller?.pane.tabs.count ?? 0, columnPanes: column.root.panes.map(\.rawValue),
                shownOthers: column.root.panes.filter { content.panes[$0] != nil }.map(\.rawValue), hasTab: tab != nil,
                edgeDocks: daemon.supports(DaemonCapability.edgeDocks.rawValue),
                tabColumnRespawn: daemon.supports(DaemonCapability.tabColumnRespawn.rawValue))
            guard let move = WindowRules().dockMove(facts) else { return }
            if case .refuse(let needs) = move {
                throw ActionFailure(message: daemon.missingCapabilityMessage(needs))
            }
            guard case .move(let respawns, let anchorID) = move, let controller, let tab else {
                throw ActionFailure.noTarget(RefusalStrings.focusedPaneHasNoTab)
            }
            var respawn: SplitRespawn?
            if respawns {
                respawn = TabMoves.respawn(for: tab, in: controller.pane, services: ctx.services)
                guard respawn != nil else { throw ActionFailure.invalidTarget(RefusalStrings.openSecondTabToDock) }
            }
            let anchor = content.panes[LayoutPaneID(rawValue: anchorID)]?.pane ?? controller.pane
            let reveal = TabHandlers.revealer(ctx, tab: tab, outcome: .newColumn(screenID: "", afterColumnID: ""), workspaceID: nil)
            TabMoves.toNewDockColumn(tab, anchor: anchor, edge: dock.edge, mode: dock.mode, width: width,
                                       respawn: respawn, services: ctx.services, completion: reveal)
        }
    }
}
