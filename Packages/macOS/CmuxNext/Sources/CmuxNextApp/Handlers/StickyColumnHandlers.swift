import CmuxNextActions
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextLayout
import CmuxNextSettings

/// Sticky columns and the strip scrollbar (plans/cmux-next/sticky-column.md).
/// Every entry point (palette, context menus, CLI verbs, `action.run`,
/// `debug.sticky`) ends in `apply`: the layout model validates and emits
/// the intent, the daemon's `set-column-sticky` changes the layout, and the
/// app shows it when the daemon's snapshot arrives (no optimistic copy).
/// Disabled with the daemon's reason on a daemon without
/// `sticky-columns-v1` (an older remote machine; the bundled same-tree
/// daemon serves it, check-daemon-capabilities.sh).
enum StickyColumnHandlers {
    static func bind(into registry: ActionRegistry, context ctx: AppActionContext) {
        let capability = DaemonCapabilities.shared.stickyColumns
        registry.bind("column.makeSticky", requires: capability, daemon: ctx.services.activeDaemon, run: { invocation in
            guard let (content, column) = ColumnHandlers.column(invocation, ctx) else { return }
            let edge = invocation["edge"]?.stringValue.flatMap(StickyEdge.init(rawValue:)) ?? column.sticky?.edge ?? defaultEdge
            let mode = invocation["mode"]?.stringValue.flatMap(StickyMode.init(rawValue:)) ?? column.sticky?.mode ?? defaultMode
            try apply(StickyColumn(edge: edge, mode: mode), to: column, in: content)
        })
        registry.bind("column.makeStickyLeft", requires: capability, daemon: ctx.services.activeDaemon, run: { invocation in
            guard let (content, column) = ColumnHandlers.column(invocation, ctx) else { return }
            try apply(StickyColumn(edge: .left, mode: column.sticky?.mode ?? defaultMode), to: column, in: content)
        })
        registry.bind("column.unstick", requires: capability, daemon: ctx.services.activeDaemon, run: { invocation in
            guard let (content, column) = ColumnHandlers.column(invocation, ctx) else { return }
            try apply(nil, to: column, in: content)
        })
        registry.bind("column.toggleStickyOverlay", requires: capability, daemon: ctx.services.activeDaemon, run: { invocation in
            guard let (content, column) = ColumnHandlers.column(invocation, ctx) else { return }
            // The targeted column if sticky, else the screen's sticky column
            // (from a strip pane), else the targeted column as a right overlay.
            let screen = content.layoutModel.screens.first { $0.layout.columns.contains { $0.id == column.id } }
            let target = column.sticky != nil ? column : screen?.layout.columns.first { $0.sticky != nil } ?? column
            let next = target.sticky.map { StickyColumn(edge: $0.edge, mode: $0.mode.toggled) } ?? StickyColumn(edge: defaultEdge, mode: .overlay)
            try apply(next, to: target, in: content)
        })
        registry.bind("tab.moveToNewStickyColumn", requires: DaemonCapabilities.shared.edgeDocks, daemon: ctx.services.activeDaemon,
                      run: { invocation in
            guard let (tab, pane) = ctx.daemonTab(invocation) else { return }
            let edge = invocation["edge"]?.stringValue.flatMap(StickyEdge.init(rawValue:)) ?? defaultEdge
            let mode = invocation["mode"]?.stringValue.flatMap(StickyMode.init(rawValue:))
            let reveal = TabHandlers.revealer(ctx, tab: tab, outcome: .newColumn(screenID: "", afterColumnID: ""), workspaceID: nil)
            TabMoves.toNewStickyColumn(tab, anchor: pane, edge: edge, mode: mode, services: ctx.services, completion: reveal)
        })
        registry.bind("layout.toggleStripScrollbar", run: { _ in
            let next = ctx.design.stripScrollbar.toggled
            ctx.design.stripScrollbar = next
            ctx.writeSetting("set strip scrollbar", StripScrollbarSetting.configPath, .string(next.rawValue))
        })
    }

    /// cmux.json `layout.stickyColumnEdge` / `layout.stickyColumnMode`.
    static var defaultEdge: StickyEdge { DesignSettings.shared.stickyColumnEdge == .left ? .left : .right }
    static var defaultMode: StickyMode { DesignSettings.shared.stickyColumnMode == .overlay ? .overlay : .docked }

    /// The one mutation path: checks the workspace's own daemon serves
    /// `sticky-columns-v1`, validates like the daemon, sends
    /// `set-column-sticky`; a refusal throws its reason.
    static func apply(_ sticky: StickyColumn?, to column: LayoutColumn, in content: WorkspaceContentController) throws {
        let capability = DaemonCapabilities.shared.stickyColumns
        guard content.daemon.supports(capability) else { throw ActionFailure(message: content.daemon.missingCapabilityMessage(capability)) }
        // Top and bottom docks need a daemon that serves edge-docks-v1.
        let docks = DaemonCapabilities.shared.edgeDocks
        if sticky?.edge.isBand == true, !content.daemon.supports(docks) {
            throw ActionFailure(message: content.daemon.missingCapabilityMessage(docks))
        }
        guard let refusal = content.layoutModel.setColumnSticky(column.id, sticky) else { return }
        switch refusal {
        case .unknownColumn: throw ActionFailure.invalidTarget(RefusalStrings.noColumnShown(column.id.rawValue))
        case .lastScrollingColumn: throw ActionFailure.invalidTarget(RefusalStrings.lastScrollingColumn)
        case .unchanged:
            throw ActionFailure.invalidTarget(sticky == nil ? RefusalStrings.columnNotSticky : RefusalStrings.columnAlreadySticky)
        }
    }
}
