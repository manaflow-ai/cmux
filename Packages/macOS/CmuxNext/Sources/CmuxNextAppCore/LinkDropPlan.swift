public import CmuxNextBridge
public import CmuxNextDaemon
import CmuxNextDesignTokens
public import CmuxNextLayout

/// What a link dropped on a layout target does (a ``LinkDragItem`` over a pane drop zone): the
/// same zones a dragged tab has. The center of a pane adds a tab there; an edge makes a split on
/// that side; a column gap a new column; a screen edge band a dock. Nil: the drop is refused (the
/// center of a pane that takes no tabs, the pinned Home column), and the preview hides.
public enum LinkDropPlan: Equatable {
    /// A new tab in the pane, selected.
    case tab(in: LayoutPaneID)
    /// A new split of the pane on `edge` holding the link.
    case split(LayoutPaneID, edge: PaneEdge)
    /// A new column after `after` (nil: before the first) on `screen`.
    case column(screen: LayoutScreenID, after: LayoutColumnID?)
    /// A new dock band on `edge` of `screen`.
    case dock(screen: LayoutScreenID, edge: CmuxNextLayout.DockEdge)

    /// The plan for a drop on `target`, asked of Rust (cmux-layout-reducer `drop_rules`, op
    /// `drop_link_plan`); `takesTabs` says whether a pane can hold a new tab (its strip shows the New
    /// Tab button), asked only for the center of a pane.
    public init?(_ target: LayoutDropTarget, takesTabs: (LayoutPaneID) -> Bool) {
        let takes = if case let .pane(pane, .center) = target { takesTabs(pane) } else { false }
        let request = LinkDropWire.Request(target: LinkDropWire.Target(target), takesTabs: takes)
        guard let reply = DropRules.call("drop_link_plan", request, as: LinkDropWire.Reply.self),
              let plan = reply.plan(for: target) else { return nil }
        self = plan
    }
}
