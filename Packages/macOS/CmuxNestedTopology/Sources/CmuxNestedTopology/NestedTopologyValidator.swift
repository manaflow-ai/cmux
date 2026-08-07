struct NestedTopologyValidator: Sendable {
    let limits: NestedTopologyLimits

    func validatedSnapshot(
        provider: NestedProviderIdentity,
        capabilities: NestedProviderCapabilities,
        workspaces: [NestedWorkspaceNode],
        tabs: [NestedTabNode],
        panes: [NestedPaneNode],
        agents: [NestedAgentNode],
        focus: NestedTopologyFocus,
        titleAuthoritySource: NestedTitleAuthoritySource
    ) throws -> NestedTopologySnapshot {
        try validateLimits()
        try validateProvider(provider)
        try validateCapabilities(capabilities)
        try validateCounts(
            workspaces: workspaces.count,
            tabs: tabs.count,
            panes: panes.count,
            agents: agents.count
        )

        var allIDs = Set<NestedNodeID>()
        for workspace in workspaces {
            try validateNode(
                id: workspace.id,
                expectedKind: .workspace,
                provider: provider,
                order: workspace.order,
                title: workspace.title,
                titleAuthoritySource: titleAuthoritySource,
                allIDs: &allIDs
            )
        }
        for tab in tabs {
            try validateNode(
                id: tab.id,
                expectedKind: .tab,
                provider: provider,
                order: tab.order,
                title: tab.title,
                titleAuthoritySource: titleAuthoritySource,
                allIDs: &allIDs
            )
        }
        for pane in panes {
            try validateNode(
                id: pane.id,
                expectedKind: .pane,
                provider: provider,
                order: pane.order,
                title: pane.title,
                titleAuthoritySource: titleAuthoritySource,
                allIDs: &allIDs
            )
        }
        for agent in agents {
            try validateNode(
                id: agent.id,
                expectedKind: .agent,
                provider: provider,
                order: agent.order,
                title: agent.title,
                titleAuthoritySource: titleAuthoritySource,
                allIDs: &allIDs
            )
        }

        let workspaceByID = Dictionary(uniqueKeysWithValues: workspaces.map { ($0.id, $0) })
        let tabByID = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0) })
        let paneByID = Dictionary(uniqueKeysWithValues: panes.map { ($0.id, $0) })
        let agentByID = Dictionary(uniqueKeysWithValues: agents.map { ($0.id, $0) })

        for tab in tabs {
            try validateParent(
                node: tab.id,
                parent: tab.workspaceID,
                expectedKind: .workspace,
                provider: provider,
                exists: workspaceByID[tab.workspaceID] != nil
            )
        }
        for pane in panes {
            try validatePaneFields(pane)
            try validateParent(
                node: pane.id,
                parent: pane.association.tabID,
                expectedKind: .tab,
                provider: provider,
                exists: tabByID[pane.association.tabID] != nil
            )
        }
        for agent in agents {
            try validateAgentFields(agent)
            try validateParent(
                node: agent.id,
                parent: agent.paneID,
                expectedKind: .pane,
                provider: provider,
                exists: paneByID[agent.paneID] != nil
            )
        }

        try validateFocus(
            focus,
            provider: provider,
            workspaces: workspaceByID,
            tabs: tabByID,
            panes: paneByID,
            agents: agentByID
        )

        return NestedTopologySnapshot(
            validatedProvider: provider,
            capabilities: capabilities,
            workspaces: workspaces.sorted(by: { $0.precedes($1) }),
            tabs: tabs.sorted(by: { $0.precedes($1) }),
            panes: panes.sorted(by: { $0.precedes($1) }),
            agents: agents.sorted(by: { $0.precedes($1) }),
            focus: focus,
            validationLimits: limits
        )
    }

    func validateEventTarget(_ id: NestedNodeID, provider: NestedProviderIdentity) throws {
        try validateIdentity(id, expectedKind: id.kind, provider: provider)
    }

    func validateEventNode(
        _ node: NestedWorkspaceNode,
        provider: NestedProviderIdentity
    ) throws {
        try validateSnapshotNode(node, provider: provider, titleAuthoritySource: .providerInput)
    }

    func validateSnapshotNode(
        _ node: NestedWorkspaceNode,
        provider: NestedProviderIdentity,
        titleAuthoritySource: NestedTitleAuthoritySource
    ) throws {
        var ids = Set<NestedNodeID>()
        try validateNode(
            id: node.id,
            expectedKind: .workspace,
            provider: provider,
            order: node.order,
            title: node.title,
            titleAuthoritySource: titleAuthoritySource,
            allIDs: &ids
        )
    }

    func validateEventNode(_ node: NestedTabNode, provider: NestedProviderIdentity) throws {
        try validateSnapshotNode(node, provider: provider, titleAuthoritySource: .providerInput)
    }

    func validateSnapshotNode(
        _ node: NestedTabNode,
        provider: NestedProviderIdentity,
        titleAuthoritySource: NestedTitleAuthoritySource
    ) throws {
        var ids = Set<NestedNodeID>()
        try validateNode(
            id: node.id,
            expectedKind: .tab,
            provider: provider,
            order: node.order,
            title: node.title,
            titleAuthoritySource: titleAuthoritySource,
            allIDs: &ids
        )
        try validateParentIdentity(
            node: node.id,
            parent: node.workspaceID,
            expectedKind: .workspace,
            provider: provider
        )
    }

    func validateEventNode(_ node: NestedPaneNode, provider: NestedProviderIdentity) throws {
        try validateSnapshotNode(node, provider: provider, titleAuthoritySource: .providerInput)
    }

    func validateSnapshotNode(
        _ node: NestedPaneNode,
        provider: NestedProviderIdentity,
        titleAuthoritySource: NestedTitleAuthoritySource
    ) throws {
        var ids = Set<NestedNodeID>()
        try validateNode(
            id: node.id,
            expectedKind: .pane,
            provider: provider,
            order: node.order,
            title: node.title,
            titleAuthoritySource: titleAuthoritySource,
            allIDs: &ids
        )
        try validatePaneFields(node)
        try validateParentIdentity(
            node: node.id,
            parent: node.association.tabID,
            expectedKind: .tab,
            provider: provider
        )
    }

    func validateEventNode(_ node: NestedAgentNode, provider: NestedProviderIdentity) throws {
        try validateSnapshotNode(node, provider: provider, titleAuthoritySource: .providerInput)
    }

    func validateSnapshotNode(
        _ node: NestedAgentNode,
        provider: NestedProviderIdentity,
        titleAuthoritySource: NestedTitleAuthoritySource
    ) throws {
        var ids = Set<NestedNodeID>()
        try validateNode(
            id: node.id,
            expectedKind: .agent,
            provider: provider,
            order: node.order,
            title: node.title,
            titleAuthoritySource: titleAuthoritySource,
            allIDs: &ids
        )
        try validateAgentFields(node)
        try validateParentIdentity(
            node: node.id,
            parent: node.paneID,
            expectedKind: .pane,
            provider: provider
        )
    }

    private func validatePaneFields(_ node: NestedPaneNode) throws {
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

    private func validateAgentFields(_ node: NestedAgentNode) throws {
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

    func validateCapability(_ capability: NestedProviderCapability) throws {
        try validateRequiredField(
            capability.rawValue,
            name: "provider.capability",
            maximumBytes: limits.maximumCapabilityBytes,
            rejectsControls: true
        )
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

    private func validateNode(
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

    private func validateIdentity(
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

    private func validateParentIdentity(
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

    private func validateFocus(
        _ focus: NestedTopologyFocus,
        provider: NestedProviderIdentity,
        workspaces: [NestedNodeID: NestedWorkspaceNode],
        tabs: [NestedNodeID: NestedTabNode],
        panes: [NestedNodeID: NestedPaneNode],
        agents: [NestedNodeID: NestedAgentNode]
    ) throws {
        if let workspaceID = focus.workspaceID {
            try validateEventTarget(workspaceID, provider: provider)
            guard workspaceID.kind == .workspace, workspaces[workspaceID] != nil else {
                throw NestedTopologyError.missingNode(id: workspaceID)
            }
        }
        if let tabID = focus.tabID {
            guard let workspaceID = focus.workspaceID else {
                throw NestedTopologyError.incompleteFocus(kind: .tab)
            }
            try validateEventTarget(tabID, provider: provider)
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
            try validateEventTarget(paneID, provider: provider)
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
            try validateEventTarget(agentID, provider: provider)
            guard agentID.kind == .agent, let agent = agents[agentID] else {
                throw NestedTopologyError.missingNode(id: agentID)
            }
            guard agent.paneID == paneID else {
                throw NestedTopologyError.inconsistentFocus(child: agentID, parent: paneID)
            }
        }
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
