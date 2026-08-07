/// Supported levels in a provider-owned virtual topology.
public enum NestedNodeKind: String, CaseIterable, Codable, Sendable {
    /// Provider workspace level.
    case workspace

    /// Provider tab level.
    case tab

    /// Provider pane level.
    case pane

    /// Agent associated with a provider pane.
    case agent

    /// One-based depth in the fixed workspace-tab-pane-agent hierarchy.
    public var depth: Int {
        switch self {
        case .workspace: 1
        case .tab: 2
        case .pane: 3
        case .agent: 4
        }
    }
}
