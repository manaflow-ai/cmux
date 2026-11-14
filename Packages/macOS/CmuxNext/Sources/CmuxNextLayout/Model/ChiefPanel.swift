public import CoreGraphics

/// A window's Chief panel (user 2026-11-06): the Chief chat over the workspace the window shows, never over Home
/// (Home already is the Chief's place). It opens only on purpose: a link clicked in the Chief, or Show/Hide Chief
/// (Cmd-I). It floats by default, dragged and resized freely; Dock pins it to an edge as a Chief-only pane that
/// takes space from the stage, and Undock floats it again. Pure value: the window controller places it, the window
/// record persists it.
///
/// ```swift
/// var panel = ChiefPanel()
/// panel.open()                                  // floating, at its last place
/// panel.isShown(stage: "ws-app", home: "home")  // true
/// panel.isShown(stage: "home", home: "home")    // false: never over Home
/// panel.dock(at: .left)                         // a Chief-only pane on the left
/// ```
public nonisolated struct ChiefPanel: Hashable, Sendable {
    /// How the panel sits in the window.
    public enum Placement: Hashable, Sendable {
        /// Over the stage at ``ChiefPanel/floatingFrame``, moved and resized by hand.
        case floating
        /// At one edge, taking space from the stage (``ChiefPanel/dockExtentPermille``).
        case docked(DockEdge)
    }

    /// Floating or docked. Kept while the panel is hidden, so it opens again the way it was.
    public var placement: Placement
    /// Whether the panel is open. An open panel still draws nothing while the window shows Home.
    public private(set) var isOpen: Bool
    /// The floating place, kept across hides, docks and relaunches.
    public var floatingFrame: ChiefPanelFrame
    /// The docked width (left, right) or height (top, bottom), permille of the content area, in
    /// ``WindowDocks/extentRange``.
    public var dockExtentPermille: Int {
        didSet { dockExtentPermille = min(max(dockExtentPermille, WindowDocks.extentRange.lowerBound), WindowDocks.extentRange.upperBound) }
    }

    /// A closed, floating panel at its first place.
    public init(placement: Placement = .floating, isOpen: Bool = false, floatingFrame: ChiefPanelFrame = .initial,
                dockExtentPermille: Int = WindowDocks.defaultExtentPermille) {
        self.placement = placement
        self.isOpen = isOpen
        self.floatingFrame = floatingFrame
        self.dockExtentPermille = min(max(dockExtentPermille, WindowDocks.extentRange.lowerBound), WindowDocks.extentRange.upperBound)
    }

    /// The edge it is docked to; nil while floating.
    public var dockedEdge: DockEdge? {
        if case let .docked(edge) = placement { return edge }
        return nil
    }

    /// Whether the panel draws while the window's stage shows `stage`: open, and the stage is a workspace that is
    /// not this window's Home (`home`).
    public func isShown(stage: String?, home: String?) -> Bool {
        guard isOpen, let stage else { return false }
        return stage != home
    }

    /// Opens the panel the way it was last placed.
    public mutating func open() { isOpen = true }

    /// Opens the panel floating at its floating place, whatever it was before: how a link from the Chief opens it,
    /// since no link click may dock the Chief (cmux#37372). The person docks it again with Dock.
    public mutating func openFloating() {
        placement = .floating
        isOpen = true
    }

    /// Hides the panel; its placement and places are kept.
    public mutating func hide() { isOpen = false }

    /// Pins the panel to `edge` and opens it.
    public mutating func dock(at edge: DockEdge) {
        placement = .docked(edge)
        isOpen = true
    }

    /// Floats a docked panel again at its floating place; false when it was not docked.
    @discardableResult
    public mutating func undock() -> Bool {
        guard dockedEdge != nil else { return false }
        placement = .floating
        return true
    }

    /// The panel's rect and the stage's rect in a content area of `bounds` (y runs down). Floating: the panel at
    /// its floating place over the whole stage. Docked: the panel takes its extent at its edge, the stage the rest.
    public func split(_ bounds: CGRect) -> (panel: CGRect, stage: CGRect) {
        guard let edge = dockedEdge else {
            let rect = floatingFrame.rect(in: bounds.size).offsetBy(dx: bounds.minX, dy: bounds.minY)
            return (rect, bounds)
        }
        let share = CGFloat(dockExtentPermille) / 1000
        switch edge {
        case .left, .right:
            let width = (bounds.width * share).rounded()
            let (panel, stage) = bounds.divided(atDistance: width, from: edge == .left ? .minXEdge : .maxXEdge)
            return (panel, stage)
        case .top, .bottom:
            let height = (bounds.height * share).rounded()
            // y runs down: the top edge is minY.
            let (panel, stage) = bounds.divided(atDistance: height, from: edge == .top ? .minYEdge : .maxYEdge)
            return (panel, stage)
        }
    }
}
