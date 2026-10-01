import CmuxNextActions
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextLayout
import CmuxNextSettings
import os

/// Sticky columns and the strip scrollbar (plans/cmux-next/sticky-column.md).
/// Every entry point (palette, context menus, CLI verbs, `action.run`,
/// `debug.sticky`) ends in `apply`, which goes through the layout model's
/// optimistic `setColumnSticky` and the daemon's `set-column-sticky`.
/// Disabled with the daemon's reason until the pinned cmux-tui serves
/// `sticky-columns-v1`.
enum StickyColumnHandlers {
    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "app.actions")

    static func bind(into registry: ActionRegistry, context ctx: AppActionContext) {
        let capability = DaemonCapabilities.shared.stickyColumns
        registry.bind("column.makeSticky", requires: capability, daemon: ctx.services.activeDaemon, run: { invocation in
            guard let (content, column) = ColumnHandlers.column(invocation, ctx) else { return }
            let edge = invocation["edge"]?.stringValue.flatMap(StickyEdge.init(rawValue:)) ?? column.sticky?.edge ?? .right
            let mode = invocation["mode"]?.stringValue.flatMap(StickyMode.init(rawValue:)) ?? column.sticky?.mode ?? .docked
            try apply(StickyColumn(edge: edge, mode: mode), to: column, in: content)
        })
        registry.bind("column.makeStickyLeft", requires: capability, daemon: ctx.services.activeDaemon, run: { invocation in
            guard let (content, column) = ColumnHandlers.column(invocation, ctx) else { return }
            try apply(StickyColumn(edge: .left, mode: column.sticky?.mode ?? .docked), to: column, in: content)
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
            let next = target.sticky.map { StickyColumn(edge: $0.edge, mode: $0.mode.toggled) } ?? StickyColumn(edge: .right, mode: .overlay)
            try apply(next, to: target, in: content)
        })
        registry.bind("layout.toggleStripScrollbar", run: { _ in
            let next = DesignSettings.shared.stripScrollbar.toggled
            DesignSettings.shared.stripScrollbar = next
            guard let settings = ctx.services.settings else { return }
            Task {
                do { try await settings.set(.string(next.rawValue), at: StripScrollbarSetting.configPath) } catch {
                    logger.error("set strip scrollbar failed: \(String(describing: error), privacy: .public)")
                }
            }
        })
    }

    /// The one mutation path: validates like the daemon, applies at once,
    /// sends `set-column-sticky`; a refusal throws its reason.
    static func apply(_ sticky: StickyColumn?, to column: LayoutColumn, in content: WorkspaceContentController) throws {
        guard let refusal = content.layoutModel.setColumnSticky(column.id, sticky) else { return }
        switch refusal {
        case .notColumns: throw ActionFailure.invalidTarget(RefusalStrings.notColumnLayout)
        case .lastScrollingColumn: throw ActionFailure.invalidTarget(RefusalStrings.lastScrollingColumn)
        case .unchanged:
            throw ActionFailure.invalidTarget(sticky == nil ? RefusalStrings.columnNotSticky : RefusalStrings.columnAlreadySticky)
        }
    }
}
