/// Pure reducer that validates snapshots and applies provider events.
///
/// The reducer owns no mutable global state and performs no I/O. Every method
/// returns a new immutable snapshot or throws without changing its input.
public struct NestedTopologyReducer: Sendable {
    /// Resource limits enforced for every snapshot and event result.
    public let limits: NestedTopologyLimits

    /// Creates a pure topology reducer.
    ///
    /// - Parameter limits: Resource limits for validation and publication.
    public init(limits: NestedTopologyLimits = .standard) {
        self.limits = limits
    }

    /// Validates, normalizes, and creates a topology snapshot.
    ///
    /// - Parameters:
    ///   - provider: Provider identity shared by all nodes.
    ///   - capabilities: Negotiated semantic capabilities.
    ///   - workspaces: Provider workspace values.
    ///   - tabs: Provider tab values.
    ///   - panes: Provider pane values.
    ///   - agents: Provider agent values.
    ///   - focus: Focused virtual path.
    /// - Returns: Validated immutable snapshot in deterministic order.
    /// - Throws: ``NestedTopologyError`` for inconsistent or unbounded input.
    public func makeSnapshot(
        provider: NestedProviderIdentity,
        capabilities: NestedProviderCapabilities,
        workspaces: [NestedWorkspaceNode],
        tabs: [NestedTabNode],
        panes: [NestedPaneNode],
        agents: [NestedAgentNode],
        focus: NestedTopologyFocus
    ) throws -> NestedTopologySnapshot {
        try validator.validatedSnapshot(
            provider: provider,
            capabilities: capabilities,
            workspaces: workspaces,
            tabs: tabs,
            panes: panes,
            agents: agents,
            focus: focus
        )
    }

    /// Applies one provider event to an immutable snapshot.
    ///
    /// - Parameters:
    ///   - event: Provider-scoped typed mutation.
    ///   - snapshot: Current validated snapshot.
    /// - Returns: New validated snapshot.
    /// - Throws: ``NestedTopologyError`` without mutating `snapshot`.
    public func applying(
        _ event: NestedTopologyEvent,
        to snapshot: NestedTopologySnapshot
    ) throws -> NestedTopologySnapshot {
        guard event.provider == snapshot.provider else {
            throw NestedTopologyError.providerMismatch(
                expected: snapshot.provider,
                actual: event.provider
            )
        }

        var workspaces = snapshot.workspaces
        var tabs = snapshot.tabs
        var panes = snapshot.panes
        var agents = snapshot.agents
        var focus = snapshot.focus

        switch event.change {
        case let .workspaceCreated(node):
            try validator.validateEventNode(node, provider: snapshot.provider)
            if let existing = workspaces.first(where: { $0.id == node.id }) {
                guard existing == node else {
                    throw NestedTopologyError.duplicateNode(id: node.id)
                }
                return snapshot
            }
            workspaces.append(node)
        case let .workspaceUpdated(node):
            try validator.validateEventNode(node, provider: snapshot.provider)
            guard let index = workspaces.firstIndex(where: { $0.id == node.id }) else {
                throw NestedTopologyError.missingNode(id: node.id)
            }
            workspaces[index] = workspaces[index].mergingUpdate(node)
        case let .tabCreated(node):
            try validator.validateEventNode(node, provider: snapshot.provider)
            if let existing = tabs.first(where: { $0.id == node.id }) {
                guard existing == node else {
                    throw NestedTopologyError.duplicateNode(id: node.id)
                }
                return snapshot
            }
            tabs.append(node)
        case let .tabUpdated(node):
            try validator.validateEventNode(node, provider: snapshot.provider)
            guard let index = tabs.firstIndex(where: { $0.id == node.id }) else {
                throw NestedTopologyError.missingNode(id: node.id)
            }
            tabs[index] = tabs[index].mergingUpdate(node)
        case let .paneCreated(node):
            try validator.validateEventNode(node, provider: snapshot.provider)
            if let existing = panes.first(where: { $0.id == node.id }) {
                guard existing == node else {
                    throw NestedTopologyError.duplicateNode(id: node.id)
                }
                return snapshot
            }
            panes.append(node)
        case let .paneUpdated(node):
            try validator.validateEventNode(node, provider: snapshot.provider)
            guard let index = panes.firstIndex(where: { $0.id == node.id }) else {
                throw NestedTopologyError.missingNode(id: node.id)
            }
            panes[index] = panes[index].mergingUpdate(node)
        case let .agentCreated(node):
            try validator.validateEventNode(node, provider: snapshot.provider)
            if let existing = agents.first(where: { $0.id == node.id }) {
                guard existing == node else {
                    throw NestedTopologyError.duplicateNode(id: node.id)
                }
                return snapshot
            }
            agents.append(node)
        case let .agentUpdated(node):
            try validator.validateEventNode(node, provider: snapshot.provider)
            guard let index = agents.firstIndex(where: { $0.id == node.id }) else {
                throw NestedTopologyError.missingNode(id: node.id)
            }
            agents[index] = agents[index].mergingUpdate(node)
        case let .nodeClosed(id):
            try validator.validateEventTarget(id, provider: snapshot.provider)
            let existed = close(
                id,
                workspaces: &workspaces,
                tabs: &tabs,
                panes: &panes,
                agents: &agents
            )
            guard existed else { return snapshot }
            focus = pruningFocus(
                focus,
                workspaces: workspaces,
                tabs: tabs,
                panes: panes,
                agents: agents
            )
        case let .focusChanged(id):
            focus = try resolvedFocus(for: id, in: snapshot)
        }

        return try makeSnapshot(
            provider: snapshot.provider,
            capabilities: snapshot.capabilities,
            workspaces: workspaces,
            tabs: tabs,
            panes: panes,
            agents: agents,
            focus: focus
        )
    }

    /// Applies an event batch atomically in provider order.
    ///
    /// If any event fails, no intermediate snapshot escapes this method.
    /// Independent events remain deterministic under batch reordering; events
    /// that target the same mutable field retain provider order semantics.
    ///
    /// - Parameters:
    ///   - events: Provider-scoped mutations in delivery order.
    ///   - snapshot: Current validated snapshot.
    /// - Returns: Final validated snapshot.
    /// - Throws: ``NestedTopologyError`` for the first invalid event.
    public func applying(
        _ events: [NestedTopologyEvent],
        to snapshot: NestedTopologySnapshot
    ) throws -> NestedTopologySnapshot {
        var reduced = snapshot
        for event in events {
            reduced = try applying(event, to: reduced)
        }
        return reduced
    }

    private var validator: NestedTopologyValidator {
        NestedTopologyValidator(limits: limits)
    }

    private func resolvedFocus(
        for id: NestedNodeID?,
        in snapshot: NestedTopologySnapshot
    ) throws -> NestedTopologyFocus {
        guard let id else { return .none }
        try validator.validateEventTarget(id, provider: snapshot.provider)

        switch id.kind {
        case .workspace:
            guard snapshot.workspaces.contains(where: { $0.id == id }) else {
                throw NestedTopologyError.missingNode(id: id)
            }
            return NestedTopologyFocus(
                workspaceID: id,
                tabID: nil,
                paneID: nil,
                agentID: nil
            )
        case .tab:
            guard let tab = snapshot.tabs.first(where: { $0.id == id }) else {
                throw NestedTopologyError.missingNode(id: id)
            }
            return NestedTopologyFocus(
                workspaceID: tab.workspaceID,
                tabID: tab.id,
                paneID: nil,
                agentID: nil
            )
        case .pane:
            guard let pane = snapshot.panes.first(where: { $0.id == id }),
                  let tab = snapshot.tabs.first(where: { $0.id == pane.association.tabID }) else {
                throw NestedTopologyError.missingNode(id: id)
            }
            return NestedTopologyFocus(
                workspaceID: tab.workspaceID,
                tabID: tab.id,
                paneID: pane.id,
                agentID: nil
            )
        case .agent:
            guard let agent = snapshot.agents.first(where: { $0.id == id }),
                  let pane = snapshot.panes.first(where: { $0.id == agent.paneID }),
                  let tab = snapshot.tabs.first(where: { $0.id == pane.association.tabID }) else {
                throw NestedTopologyError.missingNode(id: id)
            }
            return NestedTopologyFocus(
                workspaceID: tab.workspaceID,
                tabID: tab.id,
                paneID: pane.id,
                agentID: agent.id
            )
        }
    }

    private func close(
        _ id: NestedNodeID,
        workspaces: inout [NestedWorkspaceNode],
        tabs: inout [NestedTabNode],
        panes: inout [NestedPaneNode],
        agents: inout [NestedAgentNode]
    ) -> Bool {
        switch id.kind {
        case .workspace:
            guard workspaces.contains(where: { $0.id == id }) else { return false }
            let removedTabIDs = Set(tabs.filter { $0.workspaceID == id }.map(\.id))
            let removedPaneIDs = Set(
                panes.filter { removedTabIDs.contains($0.association.tabID) }.map(\.id)
            )
            workspaces.removeAll { $0.id == id }
            tabs.removeAll { removedTabIDs.contains($0.id) }
            panes.removeAll { removedPaneIDs.contains($0.id) }
            agents.removeAll { removedPaneIDs.contains($0.paneID) }
        case .tab:
            guard tabs.contains(where: { $0.id == id }) else { return false }
            let removedPaneIDs = Set(panes.filter { $0.association.tabID == id }.map(\.id))
            tabs.removeAll { $0.id == id }
            panes.removeAll { removedPaneIDs.contains($0.id) }
            agents.removeAll { removedPaneIDs.contains($0.paneID) }
        case .pane:
            guard panes.contains(where: { $0.id == id }) else { return false }
            panes.removeAll { $0.id == id }
            agents.removeAll { $0.paneID == id }
        case .agent:
            guard agents.contains(where: { $0.id == id }) else { return false }
            agents.removeAll { $0.id == id }
        }
        return true
    }

    private func pruningFocus(
        _ focus: NestedTopologyFocus,
        workspaces: [NestedWorkspaceNode],
        tabs: [NestedTabNode],
        panes: [NestedPaneNode],
        agents: [NestedAgentNode]
    ) -> NestedTopologyFocus {
        var workspaceID = focus.workspaceID
        var tabID = focus.tabID
        var paneID = focus.paneID
        var agentID = focus.agentID

        if let id = workspaceID, !workspaces.contains(where: { $0.id == id }) {
            workspaceID = nil
            tabID = nil
            paneID = nil
            agentID = nil
        } else if let id = tabID, !tabs.contains(where: { $0.id == id }) {
            tabID = nil
            paneID = nil
            agentID = nil
        } else if let id = paneID, !panes.contains(where: { $0.id == id }) {
            paneID = nil
            agentID = nil
        } else if let id = agentID, !agents.contains(where: { $0.id == id }) {
            agentID = nil
        }

        return NestedTopologyFocus(
            workspaceID: workspaceID,
            tabID: tabID,
            paneID: paneID,
            agentID: agentID
        )
    }
}
