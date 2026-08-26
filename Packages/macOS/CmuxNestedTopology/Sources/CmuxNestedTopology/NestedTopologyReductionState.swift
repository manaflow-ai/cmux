/// Copy-on-write state used to apply one bounded event batch atomically.
struct NestedTopologyReductionState: Sendable {
    var workspaces: [NestedWorkspaceNode]
    var tabs: [NestedTabNode]
    var panes: [NestedPaneNode]
    var agents: [NestedAgentNode]
    var focus: NestedTopologyFocus
    var lookup: NestedTopologyLookup
    private var removedWorkspaceIndices: Set<Int> = []
    private var removedTabIndices: Set<Int> = []
    private var removedPaneIndices: Set<Int> = []
    private var removedAgentIndices: Set<Int> = []
    var didChange = false
    var workspaceOrderingChanged = false
    var tabOrderingChanged = false
    var paneOrderingChanged = false
    var agentOrderingChanged = false
    private var workspaceIndicesChanged = false
    private var tabIndicesChanged = false
    private var paneIndicesChanged = false
    private var agentIndicesChanged = false

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

    mutating func append(_ node: NestedWorkspaceNode) {
        workspaces.append(node)
        lookup.workspaceIndices[node.id] = workspaces.count - 1
    }

    mutating func append(_ node: NestedTabNode) {
        tabs.append(node)
        lookup.tabIndices[node.id] = tabs.count - 1
        lookup.tabIDsByWorkspace[node.workspaceID, default: []].insert(node.id)
    }

    mutating func append(_ node: NestedPaneNode) {
        panes.append(node)
        lookup.paneIndices[node.id] = panes.count - 1
        lookup.paneIDsByTab[node.association.tabID, default: []].insert(node.id)
    }

    mutating func append(_ node: NestedAgentNode) {
        agents.append(node)
        lookup.agentIndices[node.id] = agents.count - 1
        lookup.agentIDsByPane[node.paneID, default: []].insert(node.id)
    }

    mutating func replace(_ node: NestedWorkspaceNode, at index: Int) {
        workspaces[index] = node
    }

    mutating func replace(_ node: NestedTabNode, at index: Int) {
        let priorParent = tabs[index].workspaceID
        tabs[index] = node
        guard priorParent != node.workspaceID else { return }
        unlinkTab(node.id, from: priorParent)
        lookup.tabIDsByWorkspace[node.workspaceID, default: []].insert(node.id)
    }

    mutating func replace(_ node: NestedPaneNode, at index: Int) {
        let priorParent = panes[index].association.tabID
        panes[index] = node
        guard priorParent != node.association.tabID else { return }
        unlinkPane(node.id, from: priorParent)
        lookup.paneIDsByTab[node.association.tabID, default: []].insert(node.id)
    }

    mutating func replace(_ node: NestedAgentNode, at index: Int) {
        let priorParent = agents[index].paneID
        agents[index] = node
        guard priorParent != node.paneID else { return }
        unlinkAgent(node.id, from: priorParent)
        lookup.agentIDsByPane[node.paneID, default: []].insert(node.id)
    }

    /// Replaces a node title without changing provider-owned topology fields.
    ///
    /// - Returns: `nil` when the node is missing, otherwise whether it changed.
    mutating func replaceTitle(_ title: NestedNodeTitle, for id: NestedNodeID) -> Bool? {
        switch id.kind {
        case .workspace:
            guard let index = lookup.workspaceIndices[id] else { return nil }
            let replacement = workspaces[index].replacingTitle(with: title)
            guard replacement != workspaces[index] else { return false }
            replace(replacement, at: index)
        case .tab:
            guard let index = lookup.tabIndices[id] else { return nil }
            let replacement = tabs[index].replacingTitle(with: title)
            guard replacement != tabs[index] else { return false }
            replace(replacement, at: index)
        case .pane:
            guard let index = lookup.paneIndices[id] else { return nil }
            let replacement = panes[index].replacingTitle(with: title)
            guard replacement != panes[index] else { return false }
            replace(replacement, at: index)
        case .agent:
            guard let index = lookup.agentIndices[id] else { return nil }
            let replacement = agents[index].replacingTitle(with: title)
            guard replacement != agents[index] else { return false }
            replace(replacement, at: index)
        }
        return true
    }

    mutating func close(_ id: NestedNodeID) -> Bool {
        let existed: Bool
        switch id.kind {
        case .workspace:
            existed = closeWorkspace(id)
        case .tab:
            existed = closeTab(id)
        case .pane:
            existed = closePane(id)
        case .agent:
            existed = closeAgent(id)
        }

        if existed {
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
        compactRemovedNodes()
        if workspaceOrderingChanged {
            workspaces.sort(by: { $0.precedes($1) })
            lookup.rebuildWorkspaces(workspaces)
        } else if workspaceIndicesChanged {
            lookup.rebuildWorkspaces(workspaces)
        }
        if tabOrderingChanged {
            tabs.sort(by: { $0.precedes($1) })
            lookup.rebuildTabs(tabs)
        } else if tabIndicesChanged {
            lookup.rebuildTabs(tabs)
        }
        if paneOrderingChanged {
            panes.sort(by: { $0.precedes($1) })
            lookup.rebuildPanes(panes)
        } else if paneIndicesChanged {
            lookup.rebuildPanes(panes)
        }
        if agentOrderingChanged {
            agents.sort(by: { $0.precedes($1) })
            lookup.rebuildAgents(agents)
        } else if agentIndicesChanged {
            lookup.rebuildAgents(agents)
        }
    }

    private mutating func compactRemovedNodes() {
        if !removedWorkspaceIndices.isEmpty {
            workspaces = workspaces.enumerated().compactMap { index, workspace in
                removedWorkspaceIndices.contains(index) ? nil : workspace
            }
            removedWorkspaceIndices.removeAll(keepingCapacity: false)
            workspaceIndicesChanged = true
        }
        if !removedTabIndices.isEmpty {
            tabs = tabs.enumerated().compactMap { index, tab in
                removedTabIndices.contains(index) ? nil : tab
            }
            removedTabIndices.removeAll(keepingCapacity: false)
            tabIndicesChanged = true
        }
        if !removedPaneIndices.isEmpty {
            panes = panes.enumerated().compactMap { index, pane in
                removedPaneIndices.contains(index) ? nil : pane
            }
            removedPaneIndices.removeAll(keepingCapacity: false)
            paneIndicesChanged = true
        }
        if !removedAgentIndices.isEmpty {
            agents = agents.enumerated().compactMap { index, agent in
                removedAgentIndices.contains(index) ? nil : agent
            }
            removedAgentIndices.removeAll(keepingCapacity: false)
            agentIndicesChanged = true
        }
    }

    private mutating func closeWorkspace(_ id: NestedNodeID) -> Bool {
        guard let index = lookup.workspaceIndices.removeValue(forKey: id) else { return false }
        removedWorkspaceIndices.insert(index)

        let childIDs = lookup.tabIDsByWorkspace.removeValue(forKey: id) ?? []
        for childID in childIDs {
            _ = closeTab(childID)
        }
        return true
    }

    private mutating func closeTab(_ id: NestedNodeID) -> Bool {
        guard let index = lookup.tabIndices.removeValue(forKey: id) else { return false }
        let tab = tabs[index]
        removedTabIndices.insert(index)
        unlinkTab(id, from: tab.workspaceID)

        let childIDs = lookup.paneIDsByTab.removeValue(forKey: id) ?? []
        for childID in childIDs {
            _ = closePane(childID)
        }
        return true
    }

    private mutating func closePane(_ id: NestedNodeID) -> Bool {
        guard let index = lookup.paneIndices.removeValue(forKey: id) else { return false }
        let pane = panes[index]
        removedPaneIndices.insert(index)
        unlinkPane(id, from: pane.association.tabID)

        let childIDs = lookup.agentIDsByPane.removeValue(forKey: id) ?? []
        for childID in childIDs {
            _ = closeAgent(childID)
        }
        return true
    }

    private mutating func closeAgent(_ id: NestedNodeID) -> Bool {
        guard let index = lookup.agentIndices.removeValue(forKey: id) else { return false }
        let agent = agents[index]
        removedAgentIndices.insert(index)
        unlinkAgent(id, from: agent.paneID)
        return true
    }

    private mutating func unlinkTab(_ id: NestedNodeID, from workspaceID: NestedNodeID) {
        guard lookup.tabIDsByWorkspace[workspaceID]?.remove(id) != nil else { return }
        if lookup.tabIDsByWorkspace[workspaceID]?.isEmpty == true {
            lookup.tabIDsByWorkspace.removeValue(forKey: workspaceID)
        }
    }

    private mutating func unlinkPane(_ id: NestedNodeID, from tabID: NestedNodeID) {
        guard lookup.paneIDsByTab[tabID]?.remove(id) != nil else { return }
        if lookup.paneIDsByTab[tabID]?.isEmpty == true {
            lookup.paneIDsByTab.removeValue(forKey: tabID)
        }
    }

    private mutating func unlinkAgent(_ id: NestedNodeID, from paneID: NestedNodeID) {
        guard lookup.agentIDsByPane[paneID]?.remove(id) != nil else { return }
        if lookup.agentIDsByPane[paneID]?.isEmpty == true {
            lookup.agentIDsByPane.removeValue(forKey: paneID)
        }
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
