/// Immutable-snapshot indexes reused by incremental topology reduction.
struct NestedTopologyLookup: Equatable, Sendable {
    var workspaceIndices: [NestedNodeID: Int]
    var tabIndices: [NestedNodeID: Int]
    var paneIndices: [NestedNodeID: Int]
    var agentIndices: [NestedNodeID: Int]

    init(
        workspaces: [NestedWorkspaceNode],
        tabs: [NestedTabNode],
        panes: [NestedPaneNode],
        agents: [NestedAgentNode]
    ) {
        workspaceIndices = [:]
        tabIndices = [:]
        paneIndices = [:]
        agentIndices = [:]
        workspaceIndices = indices(for: workspaces, id: \.id)
        tabIndices = indices(for: tabs, id: \.id)
        paneIndices = indices(for: panes, id: \.id)
        agentIndices = indices(for: agents, id: \.id)
    }

    mutating func rebuildWorkspaces(_ workspaces: [NestedWorkspaceNode]) {
        workspaceIndices = indices(for: workspaces, id: \.id)
    }

    mutating func rebuildTabs(_ tabs: [NestedTabNode]) {
        tabIndices = indices(for: tabs, id: \.id)
    }

    mutating func rebuildPanes(_ panes: [NestedPaneNode]) {
        paneIndices = indices(for: panes, id: \.id)
    }

    mutating func rebuildAgents(_ agents: [NestedAgentNode]) {
        agentIndices = indices(for: agents, id: \.id)
    }

    private func indices<Element>(
        for elements: [Element],
        id: KeyPath<Element, NestedNodeID>
    ) -> [NestedNodeID: Int] {
        var result: [NestedNodeID: Int] = [:]
        result.reserveCapacity(elements.count)
        for (offset, element) in elements.enumerated() {
            result[element[keyPath: id]] = offset
        }
        return result
    }
}
