public import CmuxNextDesign

/// A window's docked workspaces (plans/cmux-next/docked-workspace-DESIGN.md): up to four edge docks, each holding an
/// ordinary workspace, around the stage that shows the workspace the sidebar selects. Pure value: the window
/// controller places it (``WindowFrameGeometry``) and the window record persists it. Rules W1 to W5 live here.
///
/// ```swift
/// var docks = WindowDocks()
/// docks.dock("ws-logs", at: .bottom)            // W1: one dock per edge
/// docks.stage(focused: "ws-logs", previous: "ws-app", recency: [], listed: ["ws-app", "ws-logs"]) // "ws-app"
/// ```
public nonisolated struct WindowDocks: Hashable, Sendable {
    /// One edge's docked workspace.
    public struct Dock: Hashable, Sendable {
        /// The edge it holds.
        public var edge: DockEdge
        /// `WorkspaceModel.id` of the docked workspace.
        public var workspace: String
        /// `docked` takes space from the stage; `overlay` (UI "Floating") floats over its edge.
        public var mode: DockMode
        /// Width (left, right) or height (top, bottom) as permille of the frame, 100...900.
        public var extentPermille: Int
        /// Toggled off: kept, not placed.
        public var hidden: Bool
    }

    /// What Toggle did to an edge.
    public enum ToggleResult: Hashable, Sendable {
        /// The dock was hidden and shows now.
        case shown
        /// The dock showed and is hidden now.
        case hidden
        /// The edge holds no dock: the caller docks a new workspace there.
        case empty
    }

    /// The extent a new dock gets: 30% of the frame.
    public static let defaultExtentPermille = 300
    /// The extents the record may hold.
    public static let extentRange = 100...900

    /// The docks in edge order (left, right, top, bottom).
    public private(set) var all: [Dock] = []
    /// Which docks own the frame's corners (W7).
    public var orientation: FrameOrientation

    /// An empty frame.
    /// - Parameter orientation: which docks own the corners; column-major (side docks) by default.
    public init(orientation: FrameOrientation = .columnMajor) {
        self.orientation = orientation
    }

    /// The docks drawn now: every one not hidden.
    public var visible: [Dock] { all.filter { !$0.hidden } }

    /// No dock at all.
    public var isEmpty: Bool { all.isEmpty }

    /// The dock at `edge`, hidden or not.
    public func dock(at edge: DockEdge) -> Dock? { all.first { $0.edge == edge } }

    /// The edge that holds `workspace`.
    public func edge(of workspace: String) -> DockEdge? { all.first { $0.workspace == workspace }?.edge }

    /// `workspace` is in a dock (hidden or not).
    public func isDocked(_ workspace: String) -> Bool { edge(of: workspace) != nil }

    /// Docks `workspace` at `edge` (W1, W2): it leaves any other edge, and the workspace the edge held goes back to the
    /// sidebar. Returns that displaced workspace.
    @discardableResult
    public mutating func dock(_ workspace: String, at edge: DockEdge, mode: DockMode = .docked,
                       extentPermille: Int = WindowDocks.defaultExtentPermille) -> String? {
        let displaced = dock(at: edge).flatMap { $0.workspace == workspace ? nil : $0.workspace }
        all.removeAll { $0.edge == edge || $0.workspace == workspace }
        all.append(Dock(edge: edge, workspace: workspace, mode: mode,
                        extentPermille: min(max(extentPermille, Self.extentRange.lowerBound), Self.extentRange.upperBound),
                        hidden: false))
        all.sort { Self.order($0.edge) < Self.order($1.edge) }
        return displaced
    }

    /// Removes `workspace`'s dock; false when it has none.
    public mutating func undock(_ workspace: String) -> Bool {
        let before = all.count
        all.removeAll { $0.workspace == workspace }
        return all.count != before
    }

    /// Hides or shows the dock at `edge`.
    public mutating func toggle(_ edge: DockEdge) -> ToggleResult {
        guard let index = all.firstIndex(where: { $0.edge == edge }) else { return .empty }
        all[index].hidden.toggle()
        return all[index].hidden ? .hidden : .shown
    }

    /// Shows `workspace`'s dock when it is hidden (W4: selecting a docked workspace shows it). True when it changed.
    public mutating func reveal(_ workspace: String) -> Bool {
        guard let index = all.firstIndex(where: { $0.workspace == workspace && $0.hidden }) else { return false }
        all[index].hidden = false
        return true
    }

    /// Docked <-> Floating for `workspace`'s dock; the new mode, nil when it has no dock.
    public mutating func toggleFloating(_ workspace: String) -> DockMode? {
        guard let index = all.firstIndex(where: { $0.workspace == workspace }) else { return nil }
        all[index].mode = all[index].mode == .overlay ? .docked : .overlay
        return all[index].mode
    }

    /// Keeps only the docks whose workspace `keeping` accepts (W3: a workspace that closed or left the window).
    public mutating func prune(keeping: (String) -> Bool) {
        all.removeAll { !keeping($0.workspace) }
    }

    /// The workspace the stage shows (W5): the focused one unless it is docked; else the previous stage while the
    /// window lists it; else the most recent listed workspace not docked; else the first listed one not docked.
    public func stage(focused: String?, previous: String?, recency: [String], listed: [String]) -> String? {
        let candidates = Set(listed)
        func free(_ id: String?) -> String? {
            guard let id, candidates.contains(id), !isDocked(id) else { return nil }
            return id
        }
        return free(focused) ?? free(previous) ?? recency.lazy.compactMap(free).first ?? listed.lazy.compactMap(free).first
    }

    private static func order(_ edge: DockEdge) -> Int { DockEdge.allCases.firstIndex(of: edge) ?? 0 }
}
