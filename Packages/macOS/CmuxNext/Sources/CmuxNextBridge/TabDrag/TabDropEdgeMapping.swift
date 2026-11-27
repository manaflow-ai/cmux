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
    /// The edge across the pane: a split there opens the new pane on the
    /// far side of this one (`TabMoves.splitBehind`).
    public var opposite: PaneEdge {
        switch self {
        case .left: .right
        case .right: .left
        case .top: .bottom
        case .bottom: .top
        }
    }

    /// The layout's drop zone at this edge.
    public var dropZone: PaneDropZone {
        switch self {
        case .left: .left
        case .right: .right
        case .top: .top
        case .bottom: .bottom
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
