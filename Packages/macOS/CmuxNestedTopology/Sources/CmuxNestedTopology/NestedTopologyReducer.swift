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
        try applying([event], to: snapshot)
    }

    /// Applies a bounded event batch atomically in provider order.
    ///
    /// Candidate fields are validated as they cross the trust boundary. The
    /// batch mutates indexed copy-on-write state, reconciles focus against that
    /// in-progress state, and normalizes only collections whose order changed.
    /// If any event fails, no intermediate snapshot escapes this method.
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
        try validator.validateLimits()
        try validator.validateEventBatchCount(events.count)
        let prepared = try preparedSnapshot(snapshot)
        guard !events.isEmpty else { return prepared }

        var state = NestedTopologyReductionState(snapshot: prepared)
        for event in events {
            try apply(event, provider: prepared.provider, state: &state)
        }
        guard state.didChange else { return prepared }

        return state.makeSnapshot(
            provider: prepared.provider,
            capabilities: prepared.capabilities,
            limits: limits
        )
    }

    private var validator: NestedTopologyValidator {
        NestedTopologyValidator(limits: limits)
    }

    private func preparedSnapshot(
        _ snapshot: NestedTopologySnapshot
    ) throws -> NestedTopologySnapshot {
        guard snapshot.validationLimits != limits else { return snapshot }
        return try makeSnapshot(
            provider: snapshot.provider,
            capabilities: snapshot.capabilities,
            workspaces: snapshot.workspaces,
            tabs: snapshot.tabs,
            panes: snapshot.panes,
            agents: snapshot.agents,
            focus: snapshot.focus
        )
    }

    private func apply(
        _ event: NestedTopologyEvent,
        provider: NestedProviderIdentity,
        state: inout NestedTopologyReductionState
    ) throws {
        guard event.provider == provider else {
            throw NestedTopologyError.providerMismatch(expected: provider, actual: event.provider)
        }

        switch event.change {
        case let .workspaceCreated(node):
            try create(node, provider: provider, state: &state)
        case let .workspaceUpdated(node):
            try update(node, provider: provider, state: &state)
        case let .tabCreated(node):
            try create(node, provider: provider, state: &state)
        case let .tabUpdated(node):
            try update(node, provider: provider, state: &state)
        case let .paneCreated(node):
            try create(node, provider: provider, state: &state)
        case let .paneUpdated(node):
            try update(node, provider: provider, state: &state)
        case let .agentCreated(node):
            try create(node, provider: provider, state: &state)
        case let .agentUpdated(node):
            try update(node, provider: provider, state: &state)
        case let .nodeClosed(id):
            try validator.validateEventTarget(id, provider: provider)
            _ = state.close(id)
        case let .focusChanged(id):
            let focus = try resolvedFocus(for: id, provider: provider, state: state)
            if focus != state.focus {
                state.focus = focus
                state.didChange = true
            }
        }
    }

    private func create(
        _ node: NestedWorkspaceNode,
        provider: NestedProviderIdentity,
        state: inout NestedTopologyReductionState
    ) throws {
        try validator.validateEventNode(node, provider: provider)
        if let index = state.lookup.workspaceIndices[node.id] {
            guard state.workspaces[index] == node else {
                throw NestedTopologyError.duplicateNode(id: node.id)
            }
            return
        }
        try validateCounts(afterAdding: .workspace, state: state)
        state.workspaces.append(node)
        state.lookup.workspaceIndices[node.id] = state.workspaces.count - 1
        state.workspaceOrderingChanged = true
        state.didChange = true
    }

    private func update(
        _ node: NestedWorkspaceNode,
        provider: NestedProviderIdentity,
        state: inout NestedTopologyReductionState
    ) throws {
        try validator.validateEventNode(node, provider: provider)
        guard let index = state.lookup.workspaceIndices[node.id] else {
            throw NestedTopologyError.missingNode(id: node.id)
        }
        let existing = state.workspaces[index]
        let merged = existing.mergingUpdate(node)
        guard merged != existing else { return }
        state.workspaces[index] = merged
        state.workspaceOrderingChanged = existing.order != merged.order
            || state.workspaceOrderingChanged
        state.didChange = true
    }

    private func create(
        _ node: NestedTabNode,
        provider: NestedProviderIdentity,
        state: inout NestedTopologyReductionState
    ) throws {
        try validator.validateEventNode(node, provider: provider)
        try validateParent(
            node: node.id,
            parent: node.workspaceID,
            expectedKind: .workspace,
            provider: provider,
            exists: state.lookup.workspaceIndices[node.workspaceID] != nil
        )
        if let index = state.lookup.tabIndices[node.id] {
            guard state.tabs[index] == node else {
                throw NestedTopologyError.duplicateNode(id: node.id)
            }
            return
        }
        try validateCounts(afterAdding: .tab, state: state)
        state.tabs.append(node)
        state.lookup.tabIndices[node.id] = state.tabs.count - 1
        state.tabOrderingChanged = true
        state.didChange = true
    }

    private func update(
        _ node: NestedTabNode,
        provider: NestedProviderIdentity,
        state: inout NestedTopologyReductionState
    ) throws {
        try validator.validateEventNode(node, provider: provider)
        try validateParent(
            node: node.id,
            parent: node.workspaceID,
            expectedKind: .workspace,
            provider: provider,
            exists: state.lookup.workspaceIndices[node.workspaceID] != nil
        )
        guard let index = state.lookup.tabIndices[node.id] else {
            throw NestedTopologyError.missingNode(id: node.id)
        }
        let existing = state.tabs[index]
        let merged = existing.mergingUpdate(node)
        guard merged != existing else { return }
        state.tabs[index] = merged
        state.tabOrderingChanged = existing.order != merged.order
            || existing.workspaceID != merged.workspaceID
            || state.tabOrderingChanged
        state.didChange = true
        try reconcileFocus(afterUpdating: node.id, provider: provider, state: &state)
    }

    private func create(
        _ node: NestedPaneNode,
        provider: NestedProviderIdentity,
        state: inout NestedTopologyReductionState
    ) throws {
        try validator.validateEventNode(node, provider: provider)
        try validateParent(
            node: node.id,
            parent: node.association.tabID,
            expectedKind: .tab,
            provider: provider,
            exists: state.lookup.tabIndices[node.association.tabID] != nil
        )
        if let index = state.lookup.paneIndices[node.id] {
            guard state.panes[index] == node else {
                throw NestedTopologyError.duplicateNode(id: node.id)
            }
            return
        }
        try validateCounts(afterAdding: .pane, state: state)
        state.panes.append(node)
        state.lookup.paneIndices[node.id] = state.panes.count - 1
        state.paneOrderingChanged = true
        state.didChange = true
    }

    private func update(
        _ node: NestedPaneNode,
        provider: NestedProviderIdentity,
        state: inout NestedTopologyReductionState
    ) throws {
        try validator.validateEventNode(node, provider: provider)
        try validateParent(
            node: node.id,
            parent: node.association.tabID,
            expectedKind: .tab,
            provider: provider,
            exists: state.lookup.tabIndices[node.association.tabID] != nil
        )
        guard let index = state.lookup.paneIndices[node.id] else {
            throw NestedTopologyError.missingNode(id: node.id)
        }
        let existing = state.panes[index]
        let merged = existing.mergingUpdate(node)
        guard merged != existing else { return }
        state.panes[index] = merged
        state.paneOrderingChanged = existing.order != merged.order
            || existing.association.tabID != merged.association.tabID
            || state.paneOrderingChanged
        state.didChange = true
        try reconcileFocus(afterUpdating: node.id, provider: provider, state: &state)
    }

    private func create(
        _ node: NestedAgentNode,
        provider: NestedProviderIdentity,
        state: inout NestedTopologyReductionState
    ) throws {
        try validator.validateEventNode(node, provider: provider)
        try validateParent(
            node: node.id,
            parent: node.paneID,
            expectedKind: .pane,
            provider: provider,
            exists: state.lookup.paneIndices[node.paneID] != nil
        )
        if let index = state.lookup.agentIndices[node.id] {
            guard state.agents[index] == node else {
                throw NestedTopologyError.duplicateNode(id: node.id)
            }
            return
        }
        try validateCounts(afterAdding: .agent, state: state)
        state.agents.append(node)
        state.lookup.agentIndices[node.id] = state.agents.count - 1
        state.agentOrderingChanged = true
        state.didChange = true
    }

    private func update(
        _ node: NestedAgentNode,
        provider: NestedProviderIdentity,
        state: inout NestedTopologyReductionState
    ) throws {
        try validator.validateEventNode(node, provider: provider)
        try validateParent(
            node: node.id,
            parent: node.paneID,
            expectedKind: .pane,
            provider: provider,
            exists: state.lookup.paneIndices[node.paneID] != nil
        )
        guard let index = state.lookup.agentIndices[node.id] else {
            throw NestedTopologyError.missingNode(id: node.id)
        }
        let existing = state.agents[index]
        let merged = existing.mergingUpdate(node)
        guard merged != existing else { return }
        state.agents[index] = merged
        state.agentOrderingChanged = existing.order != merged.order
            || existing.paneID != merged.paneID
            || state.agentOrderingChanged
        state.didChange = true
        try reconcileFocus(afterUpdating: node.id, provider: provider, state: &state)
    }

    private func validateCounts(
        afterAdding kind: NestedNodeKind,
        state: NestedTopologyReductionState
    ) throws {
        try validator.validateCounts(
            workspaces: state.workspaces.count + (kind == .workspace ? 1 : 0),
            tabs: state.tabs.count + (kind == .tab ? 1 : 0),
            panes: state.panes.count + (kind == .pane ? 1 : 0),
            agents: state.agents.count + (kind == .agent ? 1 : 0)
        )
    }

    private func validateParent(
        node: NestedNodeID,
        parent: NestedNodeID,
        expectedKind: NestedNodeKind,
        provider: NestedProviderIdentity,
        exists: Bool
    ) throws {
        try validator.validateParent(
            node: node,
            parent: parent,
            expectedKind: expectedKind,
            provider: provider,
            exists: exists
        )
    }

    private func reconcileFocus(
        afterUpdating id: NestedNodeID,
        provider: NestedProviderIdentity,
        state: inout NestedTopologyReductionState
    ) throws {
        let affectsFocusedPath = switch id.kind {
        case .workspace: false
        case .tab: state.focus.tabID == id
        case .pane: state.focus.paneID == id
        case .agent: state.focus.agentID == id
        }
        guard affectsFocusedPath, let focusedID = state.deepestFocusedID else { return }
        state.focus = try resolvedFocus(for: focusedID, provider: provider, state: state)
    }

    private func resolvedFocus(
        for id: NestedNodeID?,
        provider: NestedProviderIdentity,
        state: NestedTopologyReductionState
    ) throws -> NestedTopologyFocus {
        guard let id else { return .none }
        try validator.validateEventTarget(id, provider: provider)

        switch id.kind {
        case .workspace:
            guard state.lookup.workspaceIndices[id] != nil else {
                throw NestedTopologyError.missingNode(id: id)
            }
            return NestedTopologyFocus(
                workspaceID: id,
                tabID: nil,
                paneID: nil,
                agentID: nil
            )
        case .tab:
            guard let tabIndex = state.lookup.tabIndices[id] else {
                throw NestedTopologyError.missingNode(id: id)
            }
            let tab = state.tabs[tabIndex]
            return NestedTopologyFocus(
                workspaceID: tab.workspaceID,
                tabID: tab.id,
                paneID: nil,
                agentID: nil
            )
        case .pane:
            guard let paneIndex = state.lookup.paneIndices[id] else {
                throw NestedTopologyError.missingNode(id: id)
            }
            let pane = state.panes[paneIndex]
            guard let tabIndex = state.lookup.tabIndices[pane.association.tabID] else {
                throw NestedTopologyError.missingNode(id: id)
            }
            let tab = state.tabs[tabIndex]
            return NestedTopologyFocus(
                workspaceID: tab.workspaceID,
                tabID: tab.id,
                paneID: pane.id,
                agentID: nil
            )
        case .agent:
            guard let agentIndex = state.lookup.agentIndices[id] else {
                throw NestedTopologyError.missingNode(id: id)
            }
            let agent = state.agents[agentIndex]
            guard let paneIndex = state.lookup.paneIndices[agent.paneID] else {
                throw NestedTopologyError.missingNode(id: id)
            }
            let pane = state.panes[paneIndex]
            guard let tabIndex = state.lookup.tabIndices[pane.association.tabID] else {
                throw NestedTopologyError.missingNode(id: id)
            }
            let tab = state.tabs[tabIndex]
            return NestedTopologyFocus(
                workspaceID: tab.workspaceID,
                tabID: tab.id,
                paneID: pane.id,
                agentID: agent.id
            )
        }
    }
}
