public import CoreGraphics

/// The panels of one app window: each floating pane that shows is one panel, a child window of the app window.
///
/// The plan is made from the window's workspace contents and says which panels show, where and in which order
/// (``panels``, back to front), and which floating panes keep a panel that does not show (``kept``). A floating
/// pane shows while its workspace is one that the window shows, its content is not covered, its screen is the
/// active one and the pane is not hidden. The daemon's list stays the state: the plan holds nothing of its own.
///
/// ``steps(from:)`` gives the acts from one plan to the next in the order that never shows a panel of a workspace
/// that the window does not show: each panel that goes leaves first, then the content changes, then each panel
/// that comes arrives.
public nonisolated struct FloatingPanelPlan: Equatable, Sendable {
    /// One workspace content of the window: the one that shows, one beside it, or one that is parked.
    public nonisolated struct Content: Equatable, Sendable {
        /// The workspace's id.
        public var workspace: String
        /// The window shows this content now (a parked content is not shown).
        public var isShown: Bool
        /// A page that belongs to the window covers the content (a top page).
        public var isCovered: Bool
        /// The floating panes of the content's active screen, back to front.
        public var floating: [LayoutFloatingPane]
        /// The floating panes of `floating` that do not show now, each with its place in the list.
        public var hidden: Set<PaneID>
        /// The floating panes of the content's other screens.
        public var elsewhere: Set<PaneID>
        /// The pane area of the active screen, in the coordinates of the displays.
        public var area: CGRect

        public init(workspace: String, isShown: Bool, isCovered: Bool, floating: [LayoutFloatingPane], hidden: Set<PaneID>,
                    elsewhere: Set<PaneID>, area: CGRect) {
            self.workspace = workspace
            self.isShown = isShown
            self.isCovered = isCovered
            self.floating = floating
            self.hidden = hidden
            self.elsewhere = elsewhere
            self.area = area
        }
    }

    /// One panel that shows.
    public nonisolated struct Panel: Equatable, Sendable {
        public var pane: PaneID
        public var workspace: String
        /// The panel's frame, in the coordinates of the displays.
        public var frame: CGRect
    }

    /// One act that takes the window's panels from a plan to the next.
    public nonisolated enum Step: Equatable, Sendable {
        /// The panel goes off the display. The pane floats still: its panel and the views in it stay.
        case leave(PaneID)
        /// The pane floats no more, or it is gone: its panel ends.
        case dissolve(PaneID)
        /// The window shows these workspaces from here on.
        case commit([String])
        /// The panel shows at another frame.
        case move(PaneID, frame: CGRect)
        /// The panel comes on the display at `frame`, above each panel that shows.
        case arrive(PaneID, frame: CGRect)
        /// The panels that show, back to front.
        case order([PaneID])

        public nonisolated enum Kind: Equatable, Sendable { case leave, dissolve, commit, move, arrive, order }

        public var kind: Kind {
            switch self {
            case .leave: .leave
            case .dissolve: .dissolve
            case .commit: .commit
            case .move: .move
            case .arrive: .arrive
            case .order: .order
            }
        }
    }

    /// The panels that show, back to front: the contents in their order, each one's list in its order.
    public private(set) var panels: [Panel] = []
    /// The floating panes that have a panel that does not show, in the order of the contents.
    public private(set) var kept: [PaneID] = []
    /// The workspaces that the window shows, in the order of the contents.
    public private(set) var workspaces: [String] = []

    /// The plan of a window with `contents`. `displays` are the frames of the displays that a panel can be on, and
    /// `scale` is the pixel grid of the frames.
    public init(contents: [Content], displays: [CGRect], scale: CGFloat) {
        var seen: Set<PaneID> = []
        for content in contents {
            if content.isShown { workspaces.append(content.workspace) }
            let shows = content.isShown && !content.isCovered
            for entry in content.floating where seen.insert(entry.pane).inserted {
                guard shows, !content.hidden.contains(entry.pane) else {
                    kept.append(entry.pane)
                    continue
                }
                let frame = FloatingPanelFrame.frame(of: entry.frame, in: content.area, scale: scale)
                panels.append(Panel(pane: entry.pane, workspace: content.workspace,
                                    frame: FloatingPanelFrame.reachable(frame, displays: displays)))
            }
            for pane in content.elsewhere.sorted() where seen.insert(pane).inserted { kept.append(pane) }
        }
    }

    /// The acts that take the window from `old` to this plan, in this order: each panel that goes (``Step/leave(_:)``,
    /// then ``Step/dissolve(_:)``), the content's change when the shown workspaces differ, each frame that changes,
    /// each panel that comes, and one order when the order of the panels is not the one that these acts give.
    public func steps(from old: FloatingPanelPlan) -> [Step] {
        let shows = Dictionary(panels.map { ($0.pane, $0) }, uniquingKeysWith: { first, _ in first })
        let showed = Dictionary(old.panels.map { ($0.pane, $0) }, uniquingKeysWith: { first, _ in first })
        let known = Set(panels.map(\.pane)).union(kept)
        var steps: [Step] = []
        for panel in old.panels where shows[panel.pane] == nil && known.contains(panel.pane) { steps.append(.leave(panel.pane)) }
        for pane in old.panels.map(\.pane) + old.kept where !known.contains(pane) { steps.append(.dissolve(pane)) }
        if workspaces != old.workspaces { steps.append(.commit(workspaces)) }
        for panel in panels {
            if let before = showed[panel.pane], before.frame != panel.frame { steps.append(.move(panel.pane, frame: panel.frame)) }
        }
        let arrivals = panels.filter { showed[$0.pane] == nil }
        for panel in arrivals { steps.append(.arrive(panel.pane, frame: panel.frame)) }
        // The panels that stay keep their order, and each arrival is above them.
        let given = old.panels.map(\.pane).filter { shows[$0] != nil } + arrivals.map(\.pane)
        let order = panels.map(\.pane)
        if given != order { steps.append(.order(order)) }
        return steps
    }
}
