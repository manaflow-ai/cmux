import CmuxNextActions
import CmuxNextLayout
import CmuxNextBridge

/// Up-front availability of column actions (every screen is a column strip):
/// on a screen's only column, width presets and column moves are disabled
/// with "Add a second column first", shown on the context menu item, instead
/// of failing after the click. Docking stays enabled there: it moves the
/// focused tab into a new docked column (DockColumnHandlers). Lookups here
/// never refuse.
enum ColumnAvailability {
    static let loneColumnDisabled: [ActionID] = [
        "column.widthOneThird", "column.widthHalf", "column.widthTwoThirds", "column.widthFull",
        "column.cycleWidth", "column.cycleWidthBack",
        "column.moveLeft", "column.moveRight", "column.focusLeft", "column.focusRight",
    ]

    static func bind(into registry: ActionRegistry, context ctx: AppActionContext) {
        for id in loneColumnDisabled {
            ActionTargetReasons.set(id, in: registry) { invocation in loneColumnReason(invocation, ctx) }
        }
        ActionTargetReasons.set("column.undock", in: registry) { invocation in
            guard let (_, column) = resolved(invocation, ctx), column.sticky == nil else { return nil }
            return RefusalStrings.columnNotSticky
        }
    }

    static func loneColumnReason(_ invocation: ActionInvocation, _ ctx: AppActionContext) -> String? {
        guard let (screen, column) = resolved(invocation, ctx), column.id == screen.implicitColumnID else { return nil }
        return RefusalStrings.addSecondColumnFirst
    }

    /// The invocation's column (targeted column, targeted pane or tab, else
    /// the focused pane's) and its screen, or nil.
    static func resolved(_ invocation: ActionInvocation, _ ctx: AppActionContext) -> (LayoutScreen, CmuxNextLayout.LayoutColumn)? {
        let contents = ctx.services.windows.controllers.compactMap(\.content)
        if let target = invocation.target {
            for content in contents {
                if target.kind == .column {
                    for screen in content.layoutModel.screens {
                        if let column = screen.column(id: CmuxNextLayout.ColumnID(target.id)) { return (screen, column) }
                    }
                    continue
                }
                let pane = content.panes.values.first { pane in
                    target.kind == .pane ? pane.paneKey == target.id : pane.stripModel.tab(StripTabID(target.id)) != nil
                }
                if let pane, let found = column(of: pane.layoutPaneID, in: content) { return found }
            }
            return nil
        }
        guard let pane = ctx.services.windows.active?.focusedPane, let content = pane.workspace else { return nil }
        return column(of: pane.layoutPaneID, in: content)
    }

    private static func column(of pane: CmuxNextLayout.PaneID, in content: WorkspaceContentController) -> (LayoutScreen, CmuxNextLayout.LayoutColumn)? {
        guard let screen = content.layoutModel.screen(containing: pane), let column = screen.column(containing: pane) else { return nil }
        return (screen, column)
    }
}
