import Foundation

/// Pure validation for nested topology snapshots and incremental events.
public struct NestedTopologyValidator: Sendable {
    /// Limits enforced during validation.
    public let limits: NestedTopologyLimits
    /// Expected provider kind for this attachment.
    public let providerKind: NestedProviderKind
    /// Expected provider instance / connection generation.
    public let providerInstanceID: NestedProviderInstanceID

    /// Creates a validator bound to one provider instance.
    public init(
        limits: NestedTopologyLimits = .default,
        providerKind: NestedProviderKind,
        providerInstanceID: NestedProviderInstanceID
    ) {
        self.limits = limits
        self.providerKind = providerKind
        self.providerInstanceID = providerInstanceID
    }

    /// Validates a full snapshot.
    public func validateSnapshot(_ snapshot: NestedTopologySnapshot) throws {
        guard snapshot.encodingVersion == NestedTopologySnapshot.currentEncodingVersion else {
            throw NestedTopologyValidationError.unsupportedEncodingVersion(snapshot.encodingVersion)
        }
        guard snapshot.provider.providerKind == providerKind,
              snapshot.provider.providerInstanceID == providerInstanceID
        else {
            throw NestedTopologyValidationError.providerInstanceMismatch
        }
        try validateUTF8ByteCount(
            snapshot.provider.providerInstanceID.rawValue,
            field: "provider_instance_id",
            limit: limits.maxProviderInstanceIDUTF8ByteCount
        )
        guard !snapshot.provider.providerInstanceID.rawValue.isEmpty else {
            throw NestedTopologyValidationError.emptyField("provider_instance_id")
        }
        try validateUTF8ByteCount(
            snapshot.provider.version,
            field: "provider_version",
            limit: limits.maxProviderVersionUTF8ByteCount
        )

        if snapshot.workspaces.count > limits.maxWorkspaces {
            throw NestedTopologyValidationError.countExceeded(
                collection: "workspaces",
                count: snapshot.workspaces.count,
                limit: limits.maxWorkspaces
            )
        }
        if snapshot.tabs.count > limits.maxTabs {
            throw NestedTopologyValidationError.countExceeded(
                collection: "tabs",
                count: snapshot.tabs.count,
                limit: limits.maxTabs
            )
        }
        if snapshot.panes.count > limits.maxPanes {
            throw NestedTopologyValidationError.countExceeded(
                collection: "panes",
                count: snapshot.panes.count,
                limit: limits.maxPanes
            )
        }
        if snapshot.agents.count > limits.maxAgents {
            throw NestedTopologyValidationError.countExceeded(
                collection: "agents",
                count: snapshot.agents.count,
                limit: limits.maxAgents
            )
        }

        var seen: Set<NestedNodeID> = []
        var kindByID: [NestedNodeID: NestedNodeKind] = [:]

        for workspace in snapshot.workspaces {
            try validateNodeID(workspace.id, expectedKind: .workspace)
            try validateDisplayTitle(workspace.displayTitle)
            try insertUnique(workspace.id, into: &seen, kindByID: &kindByID)
        }
        for tab in snapshot.tabs {
            try validateNodeID(tab.id, expectedKind: .tab)
            try validateDisplayTitle(tab.displayTitle)
            try validateParent(
                child: tab.id,
                parent: tab.workspaceID,
                expectedParentKind: .workspace,
                kindByID: kindByID
            )
            try insertUnique(tab.id, into: &seen, kindByID: &kindByID)
        }
        for pane in snapshot.panes {
            try validateNodeID(pane.id, expectedKind: .pane)
            try validateDisplayTitle(pane.displayTitle)
            try validateParent(
                child: pane.id,
                parent: pane.tabID,
                expectedParentKind: .tab,
                kindByID: kindByID
            )
            try insertUnique(pane.id, into: &seen, kindByID: &kindByID)
        }
        for agent in snapshot.agents {
            try validateNodeID(agent.id, expectedKind: .agent)
            try validateDisplayTitle(agent.displayTitle)
            try validateAgentStatus(agent.status, providerRawStatus: agent.providerRawStatus)
            try validateParent(
                child: agent.id,
                parent: agent.paneID,
                expectedParentKind: .pane,
                kindByID: kindByID
            )
            try insertUnique(agent.id, into: &seen, kindByID: &kindByID)
        }

        try validateFocus(snapshot.focus, kindByID: kindByID)
        try validateAcyclicParentage(snapshot: snapshot)
    }

    /// Validates a node ID against provider binding, kind, and size limits.
    public func validateNodeID(_ id: NestedNodeID, expectedKind: NestedNodeKind) throws {
        guard id.version == NestedNodeID.currentEncodingVersion else {
            throw NestedTopologyValidationError.unsupportedEncodingVersion(id.version)
        }
        guard id.providerKind == providerKind, id.providerInstanceID == providerInstanceID else {
            throw NestedTopologyValidationError.providerInstanceMismatch
        }
        guard id.kind == expectedKind else {
            throw NestedTopologyValidationError.kindMismatch(expected: expectedKind, actual: id.kind)
        }
        guard !id.rawID.isEmpty else {
            throw NestedTopologyValidationError.emptyField("raw_id")
        }
        try validateUTF8ByteCount(id.rawID, field: "raw_id", limit: limits.maxRawIDUTF8ByteCount)
        if id.kind.depth > limits.maxDepth {
            throw NestedTopologyValidationError.depthExceeded(
                kind: id.kind,
                depth: id.kind.depth,
                limit: limits.maxDepth
            )
        }
    }

    /// Validates focus references against known nodes.
    public func validateFocus(_ focus: NestedFocus, kindByID: [NestedNodeID: NestedNodeKind]) throws {
        if let workspaceID = focus.workspaceID {
            guard kindByID[workspaceID] == .workspace else {
                throw NestedTopologyValidationError.invalidFocus(reason: "workspace missing or wrong kind")
            }
        }
        if let tabID = focus.tabID {
            guard kindByID[tabID] == .tab else {
                throw NestedTopologyValidationError.invalidFocus(reason: "tab missing or wrong kind")
            }
        }
        if let paneID = focus.paneID {
            guard kindByID[paneID] == .pane else {
                throw NestedTopologyValidationError.invalidFocus(reason: "pane missing or wrong kind")
            }
        }
        if let agentID = focus.agentID {
            guard kindByID[agentID] == .agent else {
                throw NestedTopologyValidationError.invalidFocus(reason: "agent missing or wrong kind")
            }
        }
    }

    /// Validates agent status payload bounds and emptiness.
    public func validateAgentStatus(_ status: NestedAgentStatus, providerRawStatus: String) throws {
        let trimmed = providerRawStatus.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw NestedTopologyValidationError.invalidStatus(reason: "empty provider_raw_status")
        }
        try validateUTF8ByteCount(
            providerRawStatus,
            field: "provider_raw_status",
            limit: limits.maxProviderRawStatusUTF8ByteCount
        )
        if let normalized = NestedAgentStatus.normalized(from: providerRawStatus),
           normalized != .unknown,
           normalized != status
        {
            // A token that normalizes to `.unknown` accepts any declared status.
            // A known normalized token must match the declared status exactly
            // (including rejecting `.unknown` when the provider token is known).
            throw NestedTopologyValidationError.invalidStatus(
                reason: "status \(status.rawValue) does not match provider_raw_status"
            )
        }
    }

    /// Validates display title size.
    public func validateDisplayTitle(_ title: String) throws {
        try validateUTF8ByteCount(
            title,
            field: "display_title",
            limit: limits.maxDisplayTitleUTF8ByteCount
        )
    }

    private func validateParent(
        child: NestedNodeID,
        parent: NestedNodeID,
        expectedParentKind: NestedNodeKind,
        kindByID: [NestedNodeID: NestedNodeKind]
    ) throws {
        try validateNodeID(parent, expectedKind: expectedParentKind)
        guard kindByID[parent] == expectedParentKind else {
            throw NestedTopologyValidationError.malformedParent(
                child: child,
                parent: parent,
                reason: "parent missing"
            )
        }
        if parent == child {
            throw NestedTopologyValidationError.cycleDetected(child)
        }
    }

    private func insertUnique(
        _ id: NestedNodeID,
        into seen: inout Set<NestedNodeID>,
        kindByID: inout [NestedNodeID: NestedNodeKind]
    ) throws {
        if seen.contains(id) {
            throw NestedTopologyValidationError.duplicateNodeID(id)
        }
        seen.insert(id)
        kindByID[id] = id.kind
    }

    private func validateAcyclicParentage(snapshot: NestedTopologySnapshot) throws {
        // One shared parent map for the whole snapshot (workspace <- tab <- pane <- agent).
        // Avoids rebuilding dictionaries inside each pane/agent loop.
        var parentByChild: [NestedNodeID: NestedNodeID] = [:]
        parentByChild.reserveCapacity(snapshot.tabs.count + snapshot.panes.count + snapshot.agents.count)
        for tab in snapshot.tabs {
            parentByChild[tab.id] = tab.workspaceID
        }
        for pane in snapshot.panes {
            parentByChild[pane.id] = pane.tabID
        }
        for agent in snapshot.agents {
            parentByChild[agent.id] = agent.paneID
        }

        for tab in snapshot.tabs {
            try assertNoCycle(from: tab.id, edges: parentByChild)
        }
        for pane in snapshot.panes {
            try assertNoCycle(from: pane.id, edges: parentByChild)
        }
        for agent in snapshot.agents {
            try assertNoCycle(from: agent.id, edges: parentByChild)
        }
    }

    private func assertNoCycle(from start: NestedNodeID, edges: [NestedNodeID: NestedNodeID]) throws {
        var seen: Set<NestedNodeID> = []
        var current: NestedNodeID? = start
        while let node = current {
            if seen.contains(node) {
                throw NestedTopologyValidationError.cycleDetected(start)
            }
            seen.insert(node)
            current = edges[node]
        }
    }

    private func validateUTF8ByteCount(_ value: String, field: String, limit: Int) throws {
        let count = value.utf8.count
        if count > limit {
            throw NestedTopologyValidationError.fieldTooLarge(
                field: field,
                byteCount: count,
                limit: limit
            )
        }
    }
}
