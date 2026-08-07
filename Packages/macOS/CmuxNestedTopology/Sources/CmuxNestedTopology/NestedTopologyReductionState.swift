/// Copy-on-write state used to apply one bounded event batch atomically.
struct NestedTopologyReductionState: Sendable {
    var workspaces: [NestedWorkspaceNode]
    var tabs: [NestedTabNode]
    var panes: [NestedPaneNode]
    var agents: [NestedAgentNode]
    var focus: NestedTopologyFocus
    var lookup: NestedTopologyLookup
    var didChange = false
    var workspaceOrderingChanged = false
    var tabOrderingChanged = false
    var paneOrderingChanged = false
    var agentOrderingChanged = false

    init(snapshot: NestedTopologySnapshot) {
        workspaces = snapshot.workspaces
        tabs = snapshot.tabs
        panes = snapshot.panes
        agents = snapshot.agents
        focus = snapshot.focus
        lookup = snapshot.lookup
    }

    var deepestFocusedID: NestedNodeID? {
        focus.agentID ?? focus.paneID ?? focus.tabID ?? focus.workspaceID
    }

    mutating func close(_ id: NestedNodeID) -> Bool {
        let existed: Bool
        switch id.kind {
        case .workspace:
            guard lookup.workspaceIndices[id] != nil else { return false }
            let removedTabIDs = Set(tabs.filter { $0.workspaceID == id }.map(\.id))
            let removedPaneIDs = Set(
                panes.filter { removedTabIDs.contains($0.association.tabID) }.map(\.id)
            )
            workspaces.removeAll { $0.id == id }
            tabs.removeAll { removedTabIDs.contains($0.id) }
            panes.removeAll { removedPaneIDs.contains($0.id) }
            agents.removeAll { removedPaneIDs.contains($0.paneID) }
            existed = true
        case .tab:
            guard lookup.tabIndices[id] != nil else { return false }
            let removedPaneIDs = Set(panes.filter { $0.association.tabID == id }.map(\.id))
            tabs.removeAll { $0.id == id }
            panes.removeAll { removedPaneIDs.contains($0.id) }
            agents.removeAll { removedPaneIDs.contains($0.paneID) }
            existed = true
        case .pane:
            guard lookup.paneIndices[id] != nil else { return false }
            panes.removeAll { $0.id == id }
            agents.removeAll { $0.paneID == id }
            existed = true
        case .agent:
            guard lookup.agentIndices[id] != nil else { return false }
            agents.removeAll { $0.id == id }
            existed = true
        }

        if existed {
            rebuildLookup()
            pruneFocus()
            didChange = true
        }
        return existed
    }

    mutating func makeSnapshot(
        provider: NestedProviderIdentity,
        capabilities: NestedProviderCapabilities,
        limits: NestedTopologyLimits
    ) -> NestedTopologySnapshot {
        normalizeOrdering()
        return NestedTopologySnapshot(
            validatedProvider: provider,
            capabilities: capabilities,
            workspaces: workspaces,
            tabs: tabs,
            panes: panes,
            agents: agents,
            focus: focus,
            validationLimits: limits,
            lookup: lookup
        )
    }

    private mutating func normalizeOrdering() {
        if workspaceOrderingChanged {
            workspaces.sort(by: { $0.precedes($1) })
            lookup.rebuildWorkspaces(workspaces)
        }
        if tabOrderingChanged {
            tabs.sort(by: { $0.precedes($1) })
            lookup.rebuildTabs(tabs)
        }
        if paneOrderingChanged {
            panes.sort(by: { $0.precedes($1) })
            lookup.rebuildPanes(panes)
        }
        if agentOrderingChanged {
            agents.sort(by: { $0.precedes($1) })
            lookup.rebuildAgents(agents)
        }
    }

    private mutating func rebuildLookup() {
        lookup = NestedTopologyLookup(
            workspaces: workspaces,
            tabs: tabs,
            panes: panes,
            agents: agents
        )
    }

    private mutating func pruneFocus() {
        if let id = focus.workspaceID, lookup.workspaceIndices[id] == nil {
            focus = .none
        } else if let id = focus.tabID, lookup.tabIndices[id] == nil {
            focus = NestedTopologyFocus(
                workspaceID: focus.workspaceID,
                tabID: nil,
                paneID: nil,
                agentID: nil
            )
        } else if let id = focus.paneID, lookup.paneIndices[id] == nil {
            focus = NestedTopologyFocus(
                workspaceID: focus.workspaceID,
                tabID: focus.tabID,
                paneID: nil,
                agentID: nil
            )
        } else if let id = focus.agentID, lookup.agentIndices[id] == nil {
            focus = NestedTopologyFocus(
                workspaceID: focus.workspaceID,
                tabID: focus.tabID,
                paneID: focus.paneID,
                agentID: nil
            )
        }
    }
}
