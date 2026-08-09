struct NestedTopologyValidator: Sendable {
    let limits: NestedTopologyLimits

    private var constraints: NestedTopologyConstraintValidator {
        NestedTopologyConstraintValidator(limits: limits)
    }

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
        try constraints.validateProvider(provider)
        try constraints.validateCapabilities(capabilities)
        try validateCounts(
            workspaces: workspaces.count,
            tabs: tabs.count,
            panes: panes.count,
            agents: agents.count
        )

        var allIDs = Set<NestedNodeID>()
        for workspace in workspaces {
            try constraints.validateNode(
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
            try constraints.validateNode(
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
            try constraints.validateNode(
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
            try constraints.validateNode(
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
            try constraints.validateParent(
                node: tab.id,
                parent: tab.workspaceID,
                expectedKind: .workspace,
                provider: provider,
                exists: workspaceByID[tab.workspaceID] != nil
            )
        }
        for pane in panes {
            try constraints.validatePaneFields(pane)
            try constraints.validateParent(
                node: pane.id,
                parent: pane.association.tabID,
                expectedKind: .tab,
                provider: provider,
                exists: tabByID[pane.association.tabID] != nil
            )
        }
        for agent in agents {
            try constraints.validateAgentFields(agent)
            try constraints.validateParent(
                node: agent.id,
                parent: agent.paneID,
                expectedKind: .pane,
                provider: provider,
                exists: paneByID[agent.paneID] != nil
            )
        }

        try constraints.validateFocus(
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

    func preparedSnapshot(_ snapshot: NestedTopologySnapshot) throws -> NestedTopologySnapshot {
        guard snapshot.validationLimits != limits else { return snapshot }
        return try validatedSnapshot(
            provider: snapshot.provider,
            capabilities: snapshot.capabilities,
            workspaces: snapshot.workspaces,
            tabs: snapshot.tabs,
            panes: snapshot.panes,
            agents: snapshot.agents,
            focus: snapshot.focus,
            titleAuthoritySource: .publishedSnapshot
        )
    }

    func validateEventTarget(_ id: NestedNodeID, provider: NestedProviderIdentity) throws {
        try constraints.validateIdentity(id, expectedKind: id.kind, provider: provider)
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
        try constraints.validateNode(
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
        try constraints.validateNode(
            id: node.id,
            expectedKind: .tab,
            provider: provider,
            order: node.order,
            title: node.title,
            titleAuthoritySource: titleAuthoritySource,
            allIDs: &ids
        )
        try constraints.validateParentIdentity(
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
        try constraints.validateNode(
            id: node.id,
            expectedKind: .pane,
            provider: provider,
            order: node.order,
            title: node.title,
            titleAuthoritySource: titleAuthoritySource,
            allIDs: &ids
        )
        try constraints.validatePaneFields(node)
        try constraints.validateParentIdentity(
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
        try constraints.validateNode(
            id: node.id,
            expectedKind: .agent,
            provider: provider,
            order: node.order,
            title: node.title,
            titleAuthoritySource: titleAuthoritySource,
            allIDs: &ids
        )
        try constraints.validateAgentFields(node)
        try constraints.validateParentIdentity(
            node: node.id,
            parent: node.paneID,
            expectedKind: .pane,
            provider: provider
        )
    }

    func validateLimits() throws {
        try constraints.validateLimits()
    }

    func validateProvider(_ provider: NestedProviderIdentity) throws {
        try constraints.validateProvider(provider)
    }

    func validateCapabilities(_ capabilities: NestedProviderCapabilities) throws {
        try constraints.validateCapabilities(capabilities)
    }

    func validateCapability(_ capability: NestedProviderCapability) throws {
        try constraints.validateCapability(capability)
    }

    func validateCounts(
        workspaces: Int,
        tabs: Int,
        panes: Int,
        agents: Int
    ) throws {
        try constraints.validateCounts(
            workspaces: workspaces,
            tabs: tabs,
            panes: panes,
            agents: agents
        )
    }

    func validateEventBatchCount(_ count: Int) throws {
        try constraints.validateEventBatchCount(count)
    }

    func validateLocalTitleChange(_ change: NestedTopologyTitleChange) throws {
        try constraints.validateLocalTitleChange(change)
    }

    func validateParent(
        node: NestedNodeID,
        parent: NestedNodeID,
        expectedKind: NestedNodeKind,
        provider: NestedProviderIdentity,
        exists: Bool
    ) throws {
        try constraints.validateParent(
            node: node,
            parent: parent,
            expectedKind: expectedKind,
            provider: provider,
            exists: exists
        )
    }
}
