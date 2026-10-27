public import CmuxNextDaemon
public import CmuxNextDesign
public import CmuxNextLayout

// The layout's terms for a pane drop's edge: its zone and split axis (the
// drag's and the daemon's are CmuxNextBridge's TabDropEdgeMapping.swift).

nonisolated extension PaneDropZone {
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

nonisolated extension PaneEdge {
    public var dropZone: PaneDropZone {
        switch self {
        case .left: .left
        case .right: .right
        case .top: .top
        case .bottom: .bottom
        }
    }

    public var splitAxis: SplitAxis {
        switch self {
        case .left, .right: .horizontal
        case .top, .bottom: .vertical
        }
    }
}
