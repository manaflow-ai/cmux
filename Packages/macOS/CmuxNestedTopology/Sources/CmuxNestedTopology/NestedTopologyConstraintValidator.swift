/// Enforces scalar, identity, relationship, and resource constraints for topology values.
struct NestedTopologyConstraintValidator: Sendable {
    let limits: NestedTopologyLimits

    func validatePaneFields(_ node: NestedPaneNode) throws {
        let association = node.association
        guard association.key.paneID == node.id else {
            throw NestedTopologyError.invalidAssociationKey(
                pane: node.id,
                keyPane: association.key.paneID
            )
        }
        if association.authority == .heuristic, !association.heuristicAlreadySatisfied {
            throw NestedTopologyError.invalidHeuristicState(pane: node.id)
        }
        try validateOptionalSession(
            association.key.sessionID,
            name: "pane.association.sessionID"
        )
    }

    func validateAgentFields(_ node: NestedAgentNode) throws {
        try validateOptionalSession(node.sessionID, name: "agent.sessionID")
        try validateRequiredField(
            node.status.providerRawValue,
            name: "agent.status.providerRawValue",
            maximumBytes: limits.maximumRawStatusBytes,
            rejectsControls: true
        )
    }

    func validateLimits() throws {
        let namedLimits = [
            ("maximumWorkspaces", limits.maximumWorkspaces),
            ("maximumTabs", limits.maximumTabs),
            ("maximumPanes", limits.maximumPanes),
            ("maximumAgents", limits.maximumAgents),
            ("maximumTotalNodes", limits.maximumTotalNodes),
            ("maximumEventsPerBatch", limits.maximumEventsPerBatch),
            ("maximumDepth", limits.maximumDepth),
            ("maximumIdentifierBytes", limits.maximumIdentifierBytes),
            ("maximumTitleBytes", limits.maximumTitleBytes),
            ("maximumRawStatusBytes", limits.maximumRawStatusBytes),
            ("maximumSessionIDBytes", limits.maximumSessionIDBytes),
            ("maximumCapabilities", limits.maximumCapabilities),
            ("maximumCapabilityBytes", limits.maximumCapabilityBytes),
        ]
        for (name, value) in namedLimits where value <= 0 {
            throw NestedTopologyError.invalidLimit(name: name, value: value)
        }
    }

    func validateProvider(_ provider: NestedProviderIdentity) throws {
        try validateRequiredField(
            provider.kind.rawValue,
            name: "provider.kind",
            maximumBytes: limits.maximumIdentifierBytes,
            rejectsControls: true
        )
        try validateRequiredField(
            provider.instanceID.rawValue,
            name: "provider.instanceID",
            maximumBytes: limits.maximumIdentifierBytes,
            rejectsControls: true
        )
    }

    func validateCapabilities(_ capabilities: NestedProviderCapabilities) throws {
        guard capabilities.values.count <= limits.maximumCapabilities else {
            throw NestedTopologyError.capabilityLimitExceeded(
                actual: capabilities.values.count,
                maximum: limits.maximumCapabilities
            )
        }
        for capability in capabilities.values {
            try validateCapability(capability)
        }
    }

    func validateCounts(
        workspaces: Int,
        tabs: Int,
        panes: Int,
        agents: Int
    ) throws {
        let perKind = [
            (NestedNodeKind.workspace, workspaces, limits.maximumWorkspaces),
            (NestedNodeKind.tab, tabs, limits.maximumTabs),
            (NestedNodeKind.pane, panes, limits.maximumPanes),
            (NestedNodeKind.agent, agents, limits.maximumAgents),
        ]
        for (kind, actual, maximum) in perKind where actual > maximum {
            throw NestedTopologyError.nodeLimitExceeded(
                kind: kind,
                actual: actual,
                maximum: maximum
            )
        }
        let total = workspaces + tabs + panes + agents
        guard total <= limits.maximumTotalNodes else {
            throw NestedTopologyError.totalNodeLimitExceeded(
                actual: total,
                maximum: limits.maximumTotalNodes
            )
        }
        for (kind, actual, _) in perKind where actual > 0 && kind.depth > limits.maximumDepth {
            throw NestedTopologyError.depthLimitExceeded(
                kind: kind,
                maximumDepth: limits.maximumDepth
            )
        }
    }

    func validateEventBatchCount(_ count: Int) throws {
        guard count <= limits.maximumEventsPerBatch else {
            throw NestedTopologyError.eventBatchLimitExceeded(
                actual: count,
                maximum: limits.maximumEventsPerBatch
            )
        }
    }

    func validateLocalTitleChange(_ change: NestedTopologyTitleChange) throws {
        try validateRequiredField(
            change.title.value,
            name: "node.title",
            maximumBytes: limits.maximumTitleBytes,
            rejectsControls: true
        )
    }

    func validateNode(
        id: NestedNodeID,
        expectedKind: NestedNodeKind,
        provider: NestedProviderIdentity,
        order: Int,
        title: NestedNodeTitle?,
        titleAuthoritySource: NestedTitleAuthoritySource,
        allIDs: inout Set<NestedNodeID>
    ) throws {
        try validateIdentity(id, expectedKind: expectedKind, provider: provider)
        guard allIDs.insert(id).inserted else {
            throw NestedTopologyError.duplicateNode(id: id)
        }
        guard order >= 0 else {
            throw NestedTopologyError.invalidOrder(node: id, order: order)
        }
        if let title {
            try validateRequiredField(
                title.value,
                name: "node.title",
                maximumBytes: limits.maximumTitleBytes,
                rejectsControls: true
            )
            if case .providerInput = titleAuthoritySource {
                switch title.authority {
                case .inferred, .provider:
                    break
                case .host, .user:
                    throw NestedTopologyError.invalidProviderTitleAuthority(
                        node: id,
                        authority: title.authority
                    )
                }
            }
        }
    }

    func validateIdentity(
        _ id: NestedNodeID,
        expectedKind: NestedNodeKind,
        provider: NestedProviderIdentity
    ) throws {
        guard id.kind == expectedKind else {
            throw NestedTopologyError.invalidNodeKind(id: id, expected: expectedKind)
        }
        guard id.providerIdentity == provider else {
            throw NestedTopologyError.providerMismatch(
                expected: provider,
                actual: id.providerIdentity
            )
        }
        try validateRequiredField(
            id.rawID,
            name: "node.rawID",
            maximumBytes: limits.maximumIdentifierBytes,
            rejectsControls: true
        )
    }

    func validateParent(
        node: NestedNodeID,
        parent: NestedNodeID,
        expectedKind: NestedNodeKind,
        provider: NestedProviderIdentity,
        exists: Bool
    ) throws {
        try validateParentIdentity(
            node: node,
            parent: parent,
            expectedKind: expectedKind,
            provider: provider
        )
        guard exists else {
            throw NestedTopologyError.missingParent(node: node, parent: parent)
        }
    }

    func validateParentIdentity(
        node: NestedNodeID,
        parent: NestedNodeID,
        expectedKind: NestedNodeKind,
        provider: NestedProviderIdentity
    ) throws {
        guard parent.kind == expectedKind else {
            throw NestedTopologyError.invalidParentKind(
                node: node,
                parent: parent,
                expected: expectedKind
            )
        }
        guard parent.providerIdentity == provider else {
            throw NestedTopologyError.providerMismatch(
                expected: provider,
                actual: parent.providerIdentity
            )
        }
        try validateRequiredField(
            parent.rawID,
            name: "parent.rawID",
            maximumBytes: limits.maximumIdentifierBytes,
            rejectsControls: true
        )
    }

    func validateFocus(
        _ focus: NestedTopologyFocus,
        provider: NestedProviderIdentity,
        workspaces: [NestedNodeID: NestedWorkspaceNode],
        tabs: [NestedNodeID: NestedTabNode],
        panes: [NestedNodeID: NestedPaneNode],
        agents: [NestedNodeID: NestedAgentNode]
    ) throws {
        if let workspaceID = focus.workspaceID {
            try validateIdentity(workspaceID, expectedKind: workspaceID.kind, provider: provider)
            guard workspaceID.kind == .workspace, workspaces[workspaceID] != nil else {
                throw NestedTopologyError.missingNode(id: workspaceID)
            }
        }
        if let tabID = focus.tabID {
            guard let workspaceID = focus.workspaceID else {
                throw NestedTopologyError.incompleteFocus(kind: .tab)
            }
            try validateIdentity(tabID, expectedKind: tabID.kind, provider: provider)
            guard tabID.kind == .tab, let tab = tabs[tabID] else {
                throw NestedTopologyError.missingNode(id: tabID)
            }
            guard tab.workspaceID == workspaceID else {
                throw NestedTopologyError.inconsistentFocus(child: tabID, parent: workspaceID)
            }
        }
        if let paneID = focus.paneID {
            guard let tabID = focus.tabID else {
                throw NestedTopologyError.incompleteFocus(kind: .pane)
            }
            try validateIdentity(paneID, expectedKind: paneID.kind, provider: provider)
            guard paneID.kind == .pane, let pane = panes[paneID] else {
                throw NestedTopologyError.missingNode(id: paneID)
            }
            guard pane.association.tabID == tabID else {
                throw NestedTopologyError.inconsistentFocus(child: paneID, parent: tabID)
            }
        }
        if let agentID = focus.agentID {
            guard let paneID = focus.paneID else {
                throw NestedTopologyError.incompleteFocus(kind: .agent)
            }
            try validateIdentity(agentID, expectedKind: agentID.kind, provider: provider)
            guard agentID.kind == .agent, let agent = agents[agentID] else {
                throw NestedTopologyError.missingNode(id: agentID)
            }
            guard agent.paneID == paneID else {
                throw NestedTopologyError.inconsistentFocus(child: agentID, parent: paneID)
            }
        }
    }

    func validateCapability(_ capability: NestedProviderCapability) throws {
        try validateRequiredField(
            capability.rawValue,
            name: "provider.capability",
            maximumBytes: limits.maximumCapabilityBytes,
            rejectsControls: true
        )
    }

    private func validateOptionalSession(_ value: String?, name: String) throws {
        guard let value else { return }
        try validateRequiredField(
            value,
            name: name,
            maximumBytes: limits.maximumSessionIDBytes,
            rejectsControls: true
        )
    }

    private func validateRequiredField(
        _ value: String,
        name: String,
        maximumBytes: Int,
        rejectsControls: Bool
    ) throws {
        guard !value.isEmpty else {
            throw NestedTopologyError.emptyField(name: name)
        }
        try validateField(
            value,
            name: name,
            maximumBytes: maximumBytes,
            rejectsControls: rejectsControls
        )
    }

    private func validateField(
        _ value: String,
        name: String,
        maximumBytes: Int,
        rejectsControls: Bool
    ) throws {
        let byteCount = value.utf8.count
        guard byteCount <= maximumBytes else {
            throw NestedTopologyError.fieldTooLarge(
                name: name,
                actualBytes: byteCount,
                maximumBytes: maximumBytes
            )
        }
        if rejectsControls, value.unicodeScalars.contains(where: scalarIsControl) {
            throw NestedTopologyError.controlCharacter(name: name)
        }
    }

    private func scalarIsControl(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value <= 0x1F || (0x7F ... 0x9F).contains(scalar.value)
    }
}
