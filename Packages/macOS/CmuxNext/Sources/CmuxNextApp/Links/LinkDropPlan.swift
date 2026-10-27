import CmuxNextBridge
import CmuxNextBridgeUI
import CmuxNextDaemon
import CmuxNextLayout

/// What a link dropped on a layout target does (a ``LinkDragItem`` over a pane drop zone): the
/// same zones a dragged tab has. The center of a pane adds a tab there; an edge makes a split on
/// that side; a column gap a new column; a screen edge band a dock. Nil: the drop is refused (the
/// center of a pane that takes no tabs, the pinned Home column), and the preview hides.
enum LinkDropPlan: Equatable {
    /// A new tab in the pane, selected.
    case tab(in: LayoutPaneID)
    /// A new split of the pane on `edge` holding the link.
    case split(LayoutPaneID, edge: PaneEdge)
    /// A new column after `after` (nil: before the first) on `screen`.
    case column(screen: LayoutScreenID, after: LayoutColumnID?)
    /// A new dock band on `edge` of `screen`.
    case dock(screen: LayoutScreenID, edge: CmuxNextLayout.DockEdge)

    /// The plan for a drop on `target`; `takesTabs` says whether a pane can hold a new tab
    /// (its strip shows the New Tab button).
    init?(_ target: LayoutDropTarget, takesTabs: (LayoutPaneID) -> Bool) {
        switch target {
        case .pane(let pane, .center):
            guard takesTabs(pane) else { return nil }
            self = .tab(in: pane)
        case .pane(let pane, .left): self = .split(pane, edge: .left)
        case .pane(let pane, .right): self = .split(pane, edge: .right)
        case .pane(let pane, .top): self = .split(pane, edge: .top)
        case .pane(let pane, .bottom): self = .split(pane, edge: .bottom)
        case .newColumn(let screen, let after): self = .column(screen: screen, after: after)
        case .newDock(let screen, let edge): self = .dock(screen: screen, edge: edge)
        }
    }
}
