public import CmuxNextDaemon
public import CmuxNextDesign
public import CmuxNextLayout

// The one edge of a pane drop, in each layer's terms: the layout's zone,
// the drag's edge, the daemon's split edge.

nonisolated extension PaneDropZone {
    /// The drag's edge for this zone; nil for the center (a join).
    public var edge: TabDropEdge? {
        switch self {
        case .left: .left
        case .right: .right
        case .top: .top
        case .bottom: .bottom
        case .center: nil
        }
    }
}

nonisolated extension TabDropEdge {
    public var paneEdge: PaneEdge {
        switch self {
        case .left: .left
        case .right: .right
        case .top: .top
        case .bottom: .bottom
        }
    }
}

nonisolated extension PaneEdge {
    /// The keyboard split that opens a new pane on the far side of this
    /// edge, leaving the pane itself at this edge (`TabMoves.splitBehind`):
    /// the daemon splits right or down, then swaps toward `swapTowards`.
    public var splitBehind: (direction: SplitDirection, swapTowards: PaneDirection?) {
        switch self {
        case .left: (.right, nil)
        case .top: (.down, nil)
        case .right: (.right, .right)
        case .bottom: (.down, .down)
        }
    }

    /// The axis a split at this edge divides.
    public var splitAxis: SplitAxis {
        switch self {
        case .left, .right: .horizontal
        case .top, .bottom: .vertical
        }
    }
}
