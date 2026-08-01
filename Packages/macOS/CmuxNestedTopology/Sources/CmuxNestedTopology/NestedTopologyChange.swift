/// Typed mutation emitted by a nested-topology provider.
public enum NestedTopologyChange: Codable, Equatable, Sendable {
    /// Creates a workspace, idempotently when content already matches.
    case workspaceCreated(node: NestedWorkspaceNode)

    /// Updates an existing workspace.
    case workspaceUpdated(node: NestedWorkspaceNode)

    /// Creates a tab, idempotently when content already matches.
    case tabCreated(node: NestedTabNode)

    /// Updates an existing tab.
    case tabUpdated(node: NestedTabNode)

    /// Creates a pane, idempotently when content already matches.
    case paneCreated(node: NestedPaneNode)

    /// Updates an existing pane.
    case paneUpdated(node: NestedPaneNode)

    /// Creates an agent, idempotently when content already matches.
    case agentCreated(node: NestedAgentNode)

    /// Updates an existing agent.
    case agentUpdated(node: NestedAgentNode)

    /// Closes a node and all provider-owned descendants.
    case nodeClosed(id: NestedNodeID)

    /// Changes the coherent focused path, or clears it with `nil`.
    case focusChanged(id: NestedNodeID?)
}
