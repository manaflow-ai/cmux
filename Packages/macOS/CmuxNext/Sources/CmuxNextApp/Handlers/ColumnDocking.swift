import CmuxNextActions
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextLayout
import CmuxNextSettings
import CmuxNextWindowRules

/// Docked columns and the strip scrollbar (plans/cmux-next/dock-column.md).
/// Every entry point (palette, context menus, CLI verbs, `action.run`,
/// `debug.dock`) ends in `apply`: the layout model validates and emits
/// the intent, the daemon's `set-column-dock` changes the layout, and the
/// app shows it when the daemon's snapshot arrives (no optimistic copy).
/// Disabled with the daemon's reason on a daemon without
/// `dock-columns-v1` (an older remote machine; the bundled same-tree
/// daemon serves it, check-daemon-capabilities.sh).
enum ColumnDocking {
    static func bind(into registry: ActionRegistry, context ctx: AppActionContext) {
        DockColumnHandlers.bind(into: registry, context: ctx)
        registry.bind("tab.moveToNewDockColumn", requires: DaemonCapability.dockColumns.rawValue, daemon: ctx.services.activeDaemon,
                      run: { invocation in
            guard let (tab, pane) = ctx.daemonTab(invocation) else { return }
            let asked = ask("tab.moveToNewDockColumn", invocation)
            let edge = asked.edge ?? defaultEdge, mode = asked.mode
            let reveal = TabHandlers.revealer(ctx, tab: tab, outcome: .newColumn(screenID: "", afterColumnID: ""), workspaceID: nil)
            TabMoves.toNewDockColumn(tab, anchor: pane, edge: edge, mode: mode, services: ctx.services, completion: reveal)
        })
        registry.bind("layout.toggleStripScrollbar", run: { _ in
            let next = ctx.design.stripScrollbar.toggled
            ctx.design.stripScrollbar = next
            ctx.writeSetting("set strip scrollbar", StripScrollbarSetting.configPath, .string(next.rawValue))
        })
        ActionTargetTitles.setPaletteSettingState("layout.toggleStripScrollbar", in: registry) { ctx.design.stripScrollbar != .off }
    }

    /// cmux.json's dock edge (nil: `nearest`), that edge else right, and mode: Rust's (`handlers_placement_dock_settings`).
    static var configuredEdge: DockEdge? { settings?.configuredEdge.flatMap(DockEdge.init(rawValue:)) }
    static var defaultEdge: DockEdge { settings.flatMap { DockEdge(rawValue: $0.defaultEdge) } ?? .right }
    static var defaultMode: DockMode { settings.flatMap { DockMode(rawValue: $0.defaultMode) } ?? .docked }
    private static var settings: WindowRules.DockSettings? {
        WindowRules().dockSettings(edge: DesignSettings.shared.dockColumnEdge.rawValue, mode: DesignSettings.shared.dockColumnMode.rawValue)
    }

    /// The edge and mode dock action `action` asks for (`handlers_placement_dock_ask`).
    static func ask(_ action: String, _ invocation: ActionInvocation) -> (edge: DockEdge?, mode: DockMode?) {
        let design = DesignSettings.shared, asked = WindowRules().dockAsk(action, edge: invocation["edge"]?.stringValue,
            mode: invocation["mode"]?.stringValue, settingEdge: design.dockColumnEdge.rawValue, settingMode: design.dockColumnMode.rawValue)
        return (asked?.edge.flatMap(DockEdge.init(rawValue:)), asked?.mode.flatMap(DockMode.init(rawValue:)))
    }

    /// The one mutation path: checks the workspace's own daemon serves
    /// `dock-columns-v1`, validates like the daemon, sends
    /// `set-column-dock`; a refusal throws its reason.
    static func apply(_ dock: DockColumn?, to column: LayoutColumn, in content: WorkspaceContentController,
                      transaction: LayoutTransactionID = .make()) throws {
        // Top and bottom docks need a daemon that serves edge-docks-v1 (`chat::dock_needs`).
        let daemon = content.daemon
        if let needs = WindowRules().dockNeeds(band: dock?.edge.isBand == true, dockColumns: daemon.supports(DaemonCapability.dockColumns.rawValue),
                                               edgeDocks: daemon.supports(DaemonCapability.edgeDocks.rawValue)) {
            throw ActionFailure(message: daemon.missingCapabilityMessage(needs))
        }
        guard let refusal = content.layoutModel.setColumnDock(column.id, dock, transaction: transaction) else { return }
        // How the refusal fails is Rust's (`handlers_placement_dock_failure`); the app words its reason.
        let failure = WindowRules().dockFailure(refusal: String(describing: refusal), undocking: dock == nil)
        let message = switch failure?.reason {
        case "lastScrollingColumn": RefusalStrings.lastScrollingColumn
        case "columnNotDocked": RefusalStrings.columnNotDocked
        case "columnAlreadyDocked": RefusalStrings.columnAlreadyDocked
        default: RefusalStrings.noColumnShown(column.id.rawValue)
        }
        throw failure?.noTarget == true ? ActionFailure.noTarget(message) : ActionFailure.invalidTarget(message)
    }
}
