/// Focused nested nodes within one provider topology.
public struct NestedFocus: Hashable, Codable, Sendable {
    /// Focused workspace, if any.
    public var workspaceID: NestedNodeID?
    /// Focused tab, if any.
    public var tabID: NestedNodeID?
    /// Focused pane, if any.
    public var paneID: NestedNodeID?
    /// Focused agent, if any.
    public var agentID: NestedNodeID?

    enum CodingKeys: String, CodingKey {
        case workspaceID = "workspace_id"
        case tabID = "tab_id"
        case paneID = "pane_id"
        case agentID = "agent_id"
    }

    /// Creates a focus record.
    public init(
        workspaceID: NestedNodeID? = nil,
        tabID: NestedNodeID? = nil,
        paneID: NestedNodeID? = nil,
        agentID: NestedNodeID? = nil
    ) {
        self.workspaceID = workspaceID
        self.tabID = tabID
        self.paneID = paneID
        self.agentID = agentID
    }

    /// Empty focus.
    public static let empty = NestedFocus()
}
