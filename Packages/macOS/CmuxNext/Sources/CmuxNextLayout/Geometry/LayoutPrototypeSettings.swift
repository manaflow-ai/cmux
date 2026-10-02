public import CmuxNextDesign

/// Pinned or overlay for docks the prototype synthesizes.
public nonisolated enum LayoutPrototypeDockMode: String, Sendable, CaseIterable, TunableChoice {
    case pinned
    case overlay

    public var tunableTitle: String {
        switch self {
        case .pinned: "Pinned (takes space)"
        case .overlay: "Overlay (floats)"
        }
    }

    public var stickyMode: StickyMode { self == .pinned ? .docked : .overlay }
}

/// The prototype choice carried by `LayoutStyle`.
public nonisolated struct LayoutPrototypeSettings: Hashable, Sendable {
    public var model: LayoutPrototypeModel = .off
    public var dockEdge: LayoutPrototypeDockEdge = .bottom
    public var orientation: LayoutPrototypeOrientation = .columnMajor
    /// Mode of docks the prototype synthesizes from plain columns.
    public var dockMode: StickyMode = .docked

    public init(model: LayoutPrototypeModel = .off, dockEdge: LayoutPrototypeDockEdge = .bottom,
                orientation: LayoutPrototypeOrientation = .columnMajor, dockMode: StickyMode = .docked) {
        self.model = model
        self.dockEdge = dockEdge
        self.orientation = orientation
        self.dockMode = dockMode
    }
}
