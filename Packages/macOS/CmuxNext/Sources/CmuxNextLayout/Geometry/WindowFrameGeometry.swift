public import CoreGraphics

/// Places a window's docked workspaces and its stage (plans/cmux-next/docked-workspace-DESIGN.md G1 to G3, W6 to W8).
/// Pure: rects are y-down (`minY` is the top), whole points.
public nonisolated struct WindowFrameGeometry: Hashable, Sendable {
    /// The smallest side dock (points), unless half the frame is smaller.
    public static let minimumSide: CGFloat = 160
    /// The smallest band (top or bottom dock).
    public static let minimumBand: CGFloat = 120

    /// The space between a docked dock and the stage.
    public var gap: CGFloat

    /// - Parameter gap: the space between a docked dock and the stage (points).
    public init(gap: CGFloat) { self.gap = gap }

    /// One placed dock.
    public struct PlacedDock: Hashable, Sendable {
        /// The docked workspace.
        public var workspace: String
        /// The edge it holds.
        public var edge: DockEdge
        /// Its rect (y-down, whole points).
        public var frame: CGRect
        /// Floats over the stage (UI "Floating"); drawn above every docked one.
        public var floating: Bool
    }

    /// Where everything goes.
    public struct Placement: Hashable, Sendable {
        /// The stage's rect: the frame minus the docked docks and their gaps.
        public var stage: CGRect
        /// Back to front: docked docks, then floating ones.
        public var docks: [PlacedDock]

        /// The rect of `workspace`'s dock, nil when it is not placed.
        public func frame(of workspace: String) -> CGRect? { docks.first { $0.workspace == workspace }?.frame }

        /// The docked workspace on top at `point`; nil for the stage.
        public func workspace(at point: CGPoint) -> String? { docks.last { $0.frame.contains(point) }?.workspace }
    }

    /// Places `docks` in `rect` (y-down): corner owners by orientation first, then the others between their
    /// docked inner edges; Floating docks never cut the stage, hidden ones are not placed.
    public func place(_ docks: WindowDocks, in rect: CGRect) -> Placement {
        let visible = docks.visible
        guard !visible.isEmpty else { return Placement(stage: rect, docks: []) }
        let sides = visible.filter { !$0.edge.isBand }, bands = visible.filter(\.edge.isBand)
        var stage = rect
        var placed: [PlacedDock] = []

        func extent(_ dock: WindowDocks.Dock) -> CGFloat {
            let length = dock.edge.isBand ? rect.height : rect.width
            let both = (dock.edge.isBand ? bands : sides).count > 1
            let maximum = (length * (dock.edge.isBand ? (both ? 1.0 / 3 : 0.5) : (both ? 0.4 : 0.5))).rounded(.down)
            let minimum = min(dock.edge.isBand ? Self.minimumBand : Self.minimumSide, maximum)
            return min(max((length * CGFloat(dock.extentPermille) / 1000).rounded(.down), minimum), maximum)
        }

        /// Places `dock` along `span` (the stage's current extent across the dock's edge) and cuts the stage.
        func put(_ dock: WindowDocks.Dock) {
            let size = extent(dock)
            let frame: CGRect
            switch dock.edge {
            case .left: frame = CGRect(x: rect.minX, y: stage.minY, width: size, height: stage.height)
            case .right: frame = CGRect(x: rect.maxX - size, y: stage.minY, width: size, height: stage.height)
            case .top: frame = CGRect(x: stage.minX, y: rect.minY, width: stage.width, height: size)
            case .bottom: frame = CGRect(x: stage.minX, y: rect.maxY - size, width: stage.width, height: size)
            }
            placed.append(PlacedDock(workspace: dock.workspace, edge: dock.edge, frame: frame.integral, floating: dock.mode == .overlay))
        }

        func cut(_ dock: WindowDocks.Dock) {
            guard dock.mode == .docked, let frame = placed.first(where: { $0.workspace == dock.workspace })?.frame else { return }
            switch dock.edge {
            case .left: stage = CGRect(x: frame.maxX + gap, y: stage.minY, width: stage.maxX - frame.maxX - gap, height: stage.height)
            case .right: stage.size.width = frame.minX - gap - stage.minX
            case .top: stage = CGRect(x: stage.minX, y: frame.maxY + gap, width: stage.width, height: stage.maxY - frame.maxY - gap)
            case .bottom: stage.size.height = frame.minY - gap - stage.minY
            }
        }

        // The corner owners first, along the whole frame; the others span between the owners' docked inner edges.
        let (owners, others) = docks.orientation == .rowMajor ? (bands, sides) : (sides, bands)
        for dock in owners { put(dock) }
        for dock in owners { cut(dock) }
        for dock in others { put(dock) }
        for dock in others { cut(dock) }
        let back = placed.filter { !$0.floating }, front = placed.filter(\.floating)
        return Placement(stage: CGRect(x: stage.minX, y: stage.minY, width: max(0, stage.width), height: max(0, stage.height)),
                         docks: back + front)
    }
}
