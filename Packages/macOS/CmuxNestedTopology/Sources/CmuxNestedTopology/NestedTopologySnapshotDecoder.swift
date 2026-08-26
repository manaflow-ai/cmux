/// Bounded decoder for one untrusted nested-topology snapshot.
struct NestedTopologySnapshotDecoder {
    private let validator: NestedTopologyValidator
    private let titleAuthoritySource: NestedTitleAuthoritySource

    init(limits: NestedTopologyLimits, mode: NestedTopologySnapshotDecodingMode) {
        validator = NestedTopologyValidator(limits: limits)
        switch mode {
        case .providerInput:
            titleAuthoritySource = .providerInput
        case .trustedPublishedSnapshot:
            titleAuthoritySource = .publishedSnapshot
        }
    }

    func decode(from decoder: any Decoder) throws -> NestedTopologySnapshot {
        try validator.validateLimits()
        let container = try decoder.container(keyedBy: NestedTopologySnapshot.CodingKeys.self)
        let provider = try container.decode(
            NestedProviderIdentity.self,
            forKey: .provider
        )
        try validator.validateProvider(provider)
        let capabilities = try decodeCapabilities(from: container)
        var totalNodeCount = 0
        let workspaces: [NestedWorkspaceNode] = try decodeNodes(
            from: container,
            forKey: .workspaces,
            kind: .workspace,
            maximumCount: validator.limits.maximumWorkspaces,
            totalNodeCount: &totalNodeCount
        ) {
            try validator.validateSnapshotNode(
                $0,
                provider: provider,
                titleAuthoritySource: titleAuthoritySource
            )
        }
        let tabs: [NestedTabNode] = try decodeNodes(
            from: container,
            forKey: .tabs,
            kind: .tab,
            maximumCount: validator.limits.maximumTabs,
            totalNodeCount: &totalNodeCount
        ) {
            try validator.validateSnapshotNode(
                $0,
                provider: provider,
                titleAuthoritySource: titleAuthoritySource
            )
        }
        let panes: [NestedPaneNode] = try decodeNodes(
            from: container,
            forKey: .panes,
            kind: .pane,
            maximumCount: validator.limits.maximumPanes,
            totalNodeCount: &totalNodeCount
        ) {
            try validator.validateSnapshotNode(
                $0,
                provider: provider,
                titleAuthoritySource: titleAuthoritySource
            )
        }
        let agents: [NestedAgentNode] = try decodeNodes(
            from: container,
            forKey: .agents,
            kind: .agent,
            maximumCount: validator.limits.maximumAgents,
            totalNodeCount: &totalNodeCount
        ) {
            try validator.validateSnapshotNode(
                $0,
                provider: provider,
                titleAuthoritySource: titleAuthoritySource
            )
        }

        return try validator.validatedSnapshot(
            provider: provider,
            capabilities: capabilities,
            workspaces: workspaces,
            tabs: tabs,
            panes: panes,
            agents: agents,
            focus: container.decode(NestedTopologyFocus.self, forKey: .focus),
            titleAuthoritySource: titleAuthoritySource
        )
    }

    private func decodeCapabilities(
        from container: KeyedDecodingContainer<NestedTopologySnapshot.CodingKeys>
    ) throws -> NestedProviderCapabilities {
        var valuesContainer = try container.nestedUnkeyedContainer(forKey: .capabilities)
        if let count = valuesContainer.count,
           count > validator.limits.maximumCapabilities {
            throw NestedTopologyError.capabilityLimitExceeded(
                actual: count,
                maximum: validator.limits.maximumCapabilities
            )
        }

        var values: [NestedProviderCapability] = []
        values.reserveCapacity(valuesContainer.count ?? 0)
        while !valuesContainer.isAtEnd {
            guard values.count < validator.limits.maximumCapabilities else {
                throw NestedTopologyError.capabilityLimitExceeded(
                    actual: reportedIncrement(of: values.count),
                    maximum: validator.limits.maximumCapabilities
                )
            }
            let value = try valuesContainer.decode(NestedProviderCapability.self)
            try validator.validateCapability(value)
            values.append(value)
        }

        let capabilities = NestedProviderCapabilities(values)
        try validator.validateCapabilities(capabilities)
        return capabilities
    }

    private func decodeNodes<Node: Decodable>(
        from container: KeyedDecodingContainer<NestedTopologySnapshot.CodingKeys>,
        forKey key: NestedTopologySnapshot.CodingKeys,
        kind: NestedNodeKind,
        maximumCount: Int,
        totalNodeCount: inout Int,
        validate: (Node) throws -> Void
    ) throws -> [Node] {
        var nodesContainer = try container.nestedUnkeyedContainer(forKey: key)
        if let count = nodesContainer.count {
            guard count <= maximumCount else {
                throw NestedTopologyError.nodeLimitExceeded(
                    kind: kind,
                    actual: count,
                    maximum: maximumCount
                )
            }
            guard count <= validator.limits.maximumTotalNodes - totalNodeCount else {
                let actual = count > Int.max - totalNodeCount
                    ? Int.max
                    : totalNodeCount + count
                throw NestedTopologyError.totalNodeLimitExceeded(
                    actual: actual,
                    maximum: validator.limits.maximumTotalNodes
                )
            }
        }

        var nodes: [Node] = []
        nodes.reserveCapacity(nodesContainer.count ?? 0)
        while !nodesContainer.isAtEnd {
            guard nodes.count < maximumCount else {
                throw NestedTopologyError.nodeLimitExceeded(
                    kind: kind,
                    actual: reportedIncrement(of: nodes.count),
                    maximum: maximumCount
                )
            }
            guard totalNodeCount < validator.limits.maximumTotalNodes else {
                throw NestedTopologyError.totalNodeLimitExceeded(
                    actual: reportedIncrement(of: totalNodeCount),
                    maximum: validator.limits.maximumTotalNodes
                )
            }
            let node = try nodesContainer.decode(Node.self)
            try validate(node)
            nodes.append(node)
            totalNodeCount += 1
        }
        return nodes
    }

    private func reportedIncrement(of value: Int) -> Int {
        value == Int.max ? Int.max : value + 1
    }
}
