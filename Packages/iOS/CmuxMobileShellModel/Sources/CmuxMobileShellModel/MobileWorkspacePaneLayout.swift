/// The pane hierarchy for one remote workspace.
///
/// Pane nodes reference ``MobileTerminalPreview/ID`` values instead of copying
/// terminal metadata. ``MobileWorkspacePreview/terminals`` remains the single
/// owner of terminal titles, readiness, focus, and viewport state.
public struct MobileWorkspacePaneLayout: Equatable, Sendable {
    /// One node in the recursive workspace layout.
    public indirect enum Node: Equatable, Sendable {
        /// A leaf pane containing an ordered terminal-tab list.
        case pane(MobileWorkspacePanePreview)
        /// A split with two ordered children.
        case split(MobileWorkspaceSplitPreview)
    }

    /// The root of the workspace's split tree.
    public var root: Node

    /// Creates a workspace pane layout.
    /// - Parameter root: The recursive split-tree root.
    public init(root: Node) {
        self.root = root
    }

    /// Pane leaves in spatial depth-first order, left/top before right/bottom.
    public var panes: [MobileWorkspacePanePreview] {
        root.panes
    }

    /// Finds the pane containing a terminal.
    /// - Parameter terminalID: The terminal surface identifier.
    /// - Returns: The containing pane, if the terminal appears in the layout.
    public func pane(containing terminalID: MobileTerminalPreview.ID?) -> MobileWorkspacePanePreview? {
        guard let terminalID else { return nil }
        return panes.first { $0.terminalIDs.contains(terminalID) }
    }

    /// Returns a copy with a terminal appended to one pane.
    ///
    /// Used by deterministic local fixtures. Remote state is always replaced by
    /// the Mac's next authoritative snapshot.
    public func appendingTerminal(
        _ terminalID: MobileTerminalPreview.ID,
        to paneID: MobileWorkspacePanePreview.ID
    ) -> Self {
        Self(root: root.appendingTerminal(terminalID, to: paneID))
    }
}

/// A leaf pane in a workspace split tree.
public struct MobileWorkspacePanePreview: Identifiable, Equatable, Sendable {
    /// A session-scoped pane identifier supplied by the Mac.
    public struct ID: RawRepresentable, Hashable, Codable, Sendable, ExpressibleByStringLiteral {
        public var rawValue: String

        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        public init(stringLiteral value: String) {
            self.rawValue = value
        }
    }

    /// The pane's session-scoped identifier.
    public var id: ID
    /// Terminal surfaces in the pane's tab order.
    public var terminalIDs: [MobileTerminalPreview.ID]
    /// The tab selected in this pane on the Mac, when it is a terminal.
    public var selectedTerminalID: MobileTerminalPreview.ID?
    /// Whether this is the focused pane on the Mac.
    public var isFocused: Bool

    public init(
        id: ID,
        terminalIDs: [MobileTerminalPreview.ID],
        selectedTerminalID: MobileTerminalPreview.ID? = nil,
        isFocused: Bool = false
    ) {
        self.id = id
        self.terminalIDs = terminalIDs
        self.selectedTerminalID = selectedTerminalID
        self.isFocused = isFocused
    }
}

/// A branch in a workspace split tree.
public struct MobileWorkspaceSplitPreview: Identifiable, Equatable, Sendable {
    /// The direction in which the split's children are laid out.
    public enum Axis: String, Equatable, Sendable {
        /// First child on the left, second child on the right.
        case horizontal
        /// First child above, second child below.
        case vertical
    }

    /// A session-scoped split identifier supplied by the Mac.
    public struct ID: RawRepresentable, Hashable, Codable, Sendable, ExpressibleByStringLiteral {
        public var rawValue: String

        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        public init(stringLiteral value: String) {
            self.rawValue = value
        }
    }

    public var id: ID
    public var axis: Axis
    /// The first child's share of the split, normally between zero and one.
    public var fraction: Double
    public var first: MobileWorkspacePaneLayout.Node
    public var second: MobileWorkspacePaneLayout.Node

    public init(
        id: ID,
        axis: Axis,
        fraction: Double,
        first: MobileWorkspacePaneLayout.Node,
        second: MobileWorkspacePaneLayout.Node
    ) {
        self.id = id
        self.axis = axis
        self.fraction = fraction
        self.first = first
        self.second = second
    }
}

private extension MobileWorkspacePaneLayout.Node {
    var panes: [MobileWorkspacePanePreview] {
        switch self {
        case .pane(let pane):
            [pane]
        case .split(let split):
            split.first.panes + split.second.panes
        }
    }

    func appendingTerminal(
        _ terminalID: MobileTerminalPreview.ID,
        to paneID: MobileWorkspacePanePreview.ID
    ) -> Self {
        switch self {
        case .pane(var pane):
            guard pane.id == paneID else { return self }
            pane.terminalIDs.append(terminalID)
            pane.selectedTerminalID = terminalID
            return .pane(pane)
        case .split(var split):
            split.first = split.first.appendingTerminal(terminalID, to: paneID)
            split.second = split.second.appendingTerminal(terminalID, to: paneID)
            return .split(split)
        }
    }
}
