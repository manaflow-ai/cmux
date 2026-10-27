public import CmuxNextDaemon
public import CmuxNextDesignTokens

// The one edge of a pane drop, in each layer's terms: the drag's edge, the
// daemon's split edge. The layout's zone and axis are CmuxNextBridgeUI's
// (TabDrag/PaneDropZone+Edge.swift).

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
    public var opposite: PaneEdge {
        switch self {
        case .left: .right
        case .right: .left
        case .top: .bottom
        case .bottom: .top
        }
    }
}
