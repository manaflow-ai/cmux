public import CmuxNextDesign
public import CoreGraphics

/// Where a new pane goes, decided from the layout alone so New Pane (Auto
/// Layout) (Ctrl-Cmd-N) and `layout.newPanePlacement: split` behave the
/// same: the largest scrolling pane on screen splits along its longer side
/// (Zellij's new pane). A docked column (side dock or band) never splits.
/// The daemon still owns the result.
public struct PanePlacement {
    public nonisolated init() {}

    /// What opening a new terminal or browser does.
    public nonisolated enum Plan: Hashable, Sendable {
        /// A tab in this pane.
        case tab(in: PaneID)
        /// A new pane splitting this one along the axis.
        case split(PaneID, SplitAxis)
    }

    /// The pane Auto Layout splits and the axis.
    public nonisolated struct Split: Hashable, Sendable {
        public var pane: PaneID
        public var axis: SplitAxis
    }

    /// RED STUB: replaced by the planner in the next commit.
    public nonisolated func plan(layout: ScreenLayout, focused: PaneID, recent: [PaneID], frames: [PaneID: CGRect],
                                 placement: NewPanePlacement, tiles: Bool) -> Plan {
        .tab(in: focused)
    }

    /// RED STUB: replaced by the planner in the next commit.
    public nonisolated func autoSplit(layout: ScreenLayout, frames: [PaneID: CGRect], recent: [PaneID]) -> Split? {
        nil
    }
}
