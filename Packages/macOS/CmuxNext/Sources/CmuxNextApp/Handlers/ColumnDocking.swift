import CmuxNextActions
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextLayout
import CmuxNextSettings

/// Docked columns and the strip scrollbar (plans/cmux-next/dock-column.md).
/// Every entry point (palette, context menus, CLI verbs, `action.run`,
/// `debug.dock`) ends in `apply`: the layout model validates and emits
/// the intent, the daemon's `set-column-sticky` changes the layout, and the
/// app shows it when the daemon's snapshot arrives (no optimistic copy).
/// Disabled with the daemon's reason on a daemon without
/// `sticky-columns-v1` (an older remote machine; the bundled same-tree
/// daemon serves it, check-daemon-capabilities.sh).
enum ColumnDocking {
    static func bind(into registry: ActionRegistry, context ctx: AppActionContext) {
        DockColumnHandlers.bind(into: registry, context: ctx)
        registry.bind("tab.moveToNewDockColumn", requires: DaemonCapabilities.shared.edgeDocks, daemon: ctx.services.activeDaemon,
                      run: { invocation in
            guard let (tab, pane) = ctx.daemonTab(invocation) else { return }
            let edge = invocation["edge"]?.stringValue.flatMap(DockEdge.init(rawValue:)) ?? defaultEdge
            let mode = invocation["mode"]?.stringValue.flatMap(DockMode.init(rawValue:))
            let reveal = TabHandlers.revealer(ctx, tab: tab, outcome: .newColumn(screenID: "", afterColumnID: ""), workspaceID: nil)
            TabMoves.toNewDockColumn(tab, anchor: pane, edge: edge, mode: mode, services: ctx.services, completion: reveal)
        })
        registry.bind("layout.toggleStripScrollbar", run: { _ in
            let next = ctx.design.stripScrollbar.toggled
            ctx.design.stripScrollbar = next
            ctx.writeSetting("set strip scrollbar", StripScrollbarSetting.configPath, .string(next.rawValue))
        })
    }

    /// cmux.json `layout.dockColumnEdge` when set to an edge; nil for the
    /// default `nearest`, which leaves the choice to `DockDefaults`.
    static var configuredEdge: DockEdge? {
        switch DesignSettings.shared.dockColumnEdge {
        case .nearest: nil
        case .left: .left
        case .right: .right
        case .top: .top
        case .bottom: .bottom
        }
    }
    /// The configured edge, else right: for paths with no column to measure
    /// (a tab moved to a new docked column, `debug.dock`).
    static var defaultEdge: DockEdge { configuredEdge ?? .right }
    /// cmux.json `layout.dockColumnMode` (default docked).
    static var defaultMode: DockMode { DesignSettings.shared.dockColumnMode == .overlay ? .overlay : .docked }

    /// The one mutation path: checks the workspace's own daemon serves
    /// `sticky-columns-v1`, validates like the daemon, sends
    /// `set-column-sticky`; a refusal throws its reason.
    static func apply(_ dock: DockColumn?, to column: LayoutColumn, in content: WorkspaceContentController,
                      transaction: LayoutTransactionID = .make()) throws {
        let capability = DaemonCapabilities.shared.dockColumns
        guard content.daemon.supports(capability) else { throw ActionFailure(message: content.daemon.missingCapabilityMessage(capability)) }
        // Top and bottom docks need a daemon that serves edge-docks-v1.
        let docks = DaemonCapabilities.shared.edgeDocks
        if dock?.edge.isBand == true, !content.daemon.supports(docks) {
            throw ActionFailure(message: content.daemon.missingCapabilityMessage(docks))
        }
        guard let refusal = content.layoutModel.setColumnDock(column.id, dock, transaction: transaction) else { return }
        switch refusal {
        case .unknownColumn: throw ActionFailure.invalidTarget(RefusalStrings.noColumnShown(column.id.rawValue))
        case .lastScrollingColumn: throw ActionFailure.invalidTarget(RefusalStrings.lastScrollingColumn)
        case .unchanged:
            throw ActionFailure.invalidTarget(dock == nil ? RefusalStrings.columnNotDocked : RefusalStrings.columnAlreadyDocked)
        }
    }
}
