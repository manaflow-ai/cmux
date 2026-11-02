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
        bindDockedWorkspaces(into: registry, context: ctx)
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
            if dock.edge.isBand, !content.daemon.supports(DaemonCapability.edgeDocks.rawValue) {
                throw ActionFailure(message: content.daemon.missingCapabilityMessage(DaemonCapability.edgeDocks.rawValue))
            }
            if abs(column.width - width) > 0.001 {
                content.layoutModel.setColumnWidth(column.id, width: width, transaction: transaction, phase: .ended)
            }
            try ColumnDocking.apply(dock, to: column, in: content, transaction: transaction)
        case .moveTab(let pane, let dock, let width):
            let docks = DaemonCapability.edgeDocks.rawValue
            guard content.daemon.supports(docks) else { throw ActionFailure(message: content.daemon.missingCapabilityMessage(docks)) }
            guard let controller = content.panes[pane], let tab = controller.selectedTab else {
                throw ActionFailure.noTarget(RefusalStrings.focusedPaneHasNoTab)
            }
            // The column keeps a tab to scroll: the pane keeps another tab,
            // the column keeps another pane, or a fresh tab stays behind.
            var respawn: SplitRespawn?
            if controller.pane.tabs.count == 1, column.root.panes.count == 1 {
                let capability = DaemonCapability.tabColumnRespawn.rawValue
                guard content.daemon.supports(capability) else {
                    throw ActionFailure(message: content.daemon.missingCapabilityMessage(capability))
                }
                respawn = TabMoves.respawn(for: tab, in: controller.pane, services: ctx.services)
                guard respawn != nil else { throw ActionFailure.invalidTarget(RefusalStrings.openSecondTabToDock) }
            }
            // The anchor only places the new column on the screen. A pane's
            // only tab cannot leave through its own pane (the daemon refuses
            // that as a split), so another pane of the column anchors it.
            let anchor = respawn != nil || controller.pane.tabs.count > 1 ? controller.pane
                : column.root.panes.lazy.filter { $0 != pane }.compactMap { content.panes[$0]?.pane }.first ?? controller.pane
            let reveal = TabHandlers.revealer(ctx, tab: tab, outcome: .newColumn(screenID: "", afterColumnID: ""), workspaceID: nil)
            TabMoves.toNewDockColumn(tab, anchor: anchor, edge: dock.edge, mode: dock.mode, width: width,
                                       respawn: respawn, services: ctx.services, completion: reveal)
        }
    }
}

// Docked workspaces (plans/cmux-next/docked-workspace-DESIGN.md), next to docked columns: the window frame one level up.
/// Dock Workspace Left/Right/Top/Bottom, Undock Workspace, Float Docked Workspace, Toggle Left/Right/Top/Bottom Dock
/// and Toggle Dock Corners (plans/cmux-next/docked-workspace-DESIGN.md). Every entry point (palette, CLI verb, MCP,
/// `action.run`) ends in one `WindowController` frame operation, which changes window view state in this turn: no
/// await, no daemon round trip (a dock on an empty edge creates its workspace in the background and docks it when the
/// daemon reports it). Off (Debug Settings `window.dockedWorkspaces`), each refuses with that reason.
extension DockColumnHandlers {
    static func bindDockedWorkspaces(into registry: ActionRegistry, context: AppActionContext) {
        let edges: [(DockEdge, ActionID, ActionID)] = [
            (.left, "workspace.dockLeft", "window.toggleDockLeft"), (.right, "workspace.dockRight", "window.toggleDockRight"),
            (.top, "workspace.dockTop", "window.toggleDockTop"), (.bottom, "workspace.dockBottom", "window.toggleDockBottom"),
        ]
        for (edge, dock, toggle) in edges {
            registry.bindEffect(dock) { invocation in
                guard LayoutTunables.dockedWorkspaces.value else { return .refused(RefusalStrings.dockedWorkspacesOff) }
                guard let (id, window) = dockedWorkspaceOwner(invocation, context) else { return .refused(RefusalStrings.noWorkspaceToActOn) }
                window.dockWorkspace(id, at: edge)
                return .done
            }
            registry.bindEffect(toggle) { invocation in
                guard LayoutTunables.dockedWorkspaces.value else { return .refused(RefusalStrings.dockedWorkspacesOff) }
                guard let window = try? context.window(invocation) else { return .refused(RefusalStrings.noWindowOpen) }
                window.toggleDock(edge, cwd: invocation["cwd"]?.stringValue)
                return .done
            }
        }
        registry.bindEffect("workspace.undock") { invocation in
            guard LayoutTunables.dockedWorkspaces.value else { return .refused(RefusalStrings.dockedWorkspacesOff) }
            guard let (id, window) = dockedWorkspaceOwner(invocation, context) else { return .refused(RefusalStrings.noWorkspaceToActOn) }
            // A person sees it on the stage; automation never moves the view (socket focus policy).
            guard window.undockWorkspace(id, show: invocation.origin == .user) else { return .refused(RefusalStrings.workspaceNotDocked) }
            return .done
        }
        registry.bindEffect("workspace.toggleDockFloating") { invocation in
            guard LayoutTunables.dockedWorkspaces.value else { return .refused(RefusalStrings.dockedWorkspacesOff) }
            guard let (id, window) = dockedWorkspaceOwner(invocation, context) else { return .refused(RefusalStrings.noWorkspaceToActOn) }
            guard window.toggleDockFloating(id) != nil else { return .refused(RefusalStrings.workspaceNotDocked) }
            return .done
        }
        registry.bindEffect("window.toggleDockOrientation") { invocation in
            guard LayoutTunables.dockedWorkspaces.value else { return .refused(RefusalStrings.dockedWorkspacesOff) }
            guard let window = try? context.window(invocation) else { return .refused(RefusalStrings.noWindowOpen) }
            window.toggleDockOrientation()
            return .done
        }
    }

    /// The targeted workspace (default: the focused one) and the open window that lists it.
    private static func dockedWorkspaceOwner(_ invocation: ActionInvocation, _ context: AppActionContext) -> (String, WindowController)? {
        guard let (model, _) = try? context.workspace(invocation),
              let windowID = context.services.windows.registry.value.owner(of: model.id),
              let window = context.services.windows.controller(for: windowID) else { return nil }
        return (model.id, window)
    }
}
