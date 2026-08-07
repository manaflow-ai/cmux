/// One coherent focused path through a nested topology.
///
/// Optional IDs make multiple focus values at the same level unrepresentable.
/// Snapshot validation additionally requires every descendant to belong to its
/// focused ancestor.
public struct NestedTopologyFocus: Codable, Equatable, Sendable {
    /// Topology with no focused virtual descendant.
    public static let none = NestedTopologyFocus(
        workspaceID: nil,
        tabID: nil,
        paneID: nil,
        agentID: nil
    )

    /// Focused provider workspace.
    public let workspaceID: NestedNodeID?

    /// Focused provider tab.
    public let tabID: NestedNodeID?

    /// Focused provider pane.
    public let paneID: NestedNodeID?

    /// Focused provider agent.
    public let agentID: NestedNodeID?

    /// Creates a focused virtual path.
    ///
    /// Validation occurs when the focus is installed in a snapshot.
    ///
    /// - Parameters:
    ///   - workspaceID: Focused provider workspace.
    ///   - tabID: Focused provider tab.
    ///   - paneID: Focused provider pane.
    ///   - agentID: Focused provider agent.
    public init(
        workspaceID: NestedNodeID?,
        tabID: NestedNodeID?,
        paneID: NestedNodeID?,
        agentID: NestedNodeID?
    ) {
        self.workspaceID = workspaceID
        self.tabID = tabID
        self.paneID = paneID
        self.agentID = agentID
    }
}
