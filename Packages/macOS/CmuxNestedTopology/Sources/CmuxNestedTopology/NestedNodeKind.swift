/// Kind of node inside a provider-owned nested topology tree.
///
/// Hierarchy is fixed: workspace → tab → pane → agent.
public enum NestedNodeKind: String, Codable, Sendable, Hashable, CaseIterable, Comparable {
    /// Provider workspace root.
    case workspace
    /// Tab under a workspace.
    case tab
    /// Pane under a tab.
    case pane
    /// Agent decoration/child under a pane.
    case agent

    /// Depth from the topology root (workspace = 0).
    public var depth: Int {
        switch self {
        case .workspace: 0
        case .tab: 1
        case .pane: 2
        case .agent: 3
        }
    }

    /// Required parent kind, if any.
    public var requiredParentKind: NestedNodeKind? {
        switch self {
        case .workspace: nil
        case .tab: .workspace
        case .pane: .tab
        case .agent: .pane
        }
    }

    public static func < (lhs: NestedNodeKind, rhs: NestedNodeKind) -> Bool {
        lhs.depth < rhs.depth
    }
}
