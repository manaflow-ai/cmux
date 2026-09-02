/// Pure reducer that validates and applies nested topology events.
///
/// The reducer is provider-neutral: it never opens sockets or touches UI. Apply
/// events serially for one attachment / provider instance.
public struct NestedTopologyReducer: Sendable {
    /// Resource limits.
    public let limits: NestedTopologyLimits
    /// Expected provider kind.
    public let providerKind: NestedProviderKind
    /// Expected provider instance / connection generation.
    public let providerInstanceID: NestedProviderInstanceID
    /// Current immutable snapshot, if installed.
    public private(set) var snapshot: NestedTopologySnapshot?

    private var validator: NestedTopologyValidator {
        NestedTopologyValidator(
            limits: limits,
            providerKind: providerKind,
            providerInstanceID: providerInstanceID
        )
    }

    /// Creates an empty reducer bound to one provider instance.
    public init(
        providerKind: NestedProviderKind,
        providerInstanceID: NestedProviderInstanceID,
        limits: NestedTopologyLimits = .default
    ) {
        self.providerKind = providerKind
        self.providerInstanceID = providerInstanceID
        self.limits = limits
        self.snapshot = nil
    }

    /// Applies one event, replacing ``snapshot`` on success.
    ///
    /// - Parameter event: Snapshot replacement or incremental mutation.
    /// - Returns: Whether the published snapshot changed.
    /// - Throws: ``NestedTopologyValidationError`` on deterministic validation failure.
    @discardableResult
    public mutating func apply(_ event: NestedTopologyEvent) throws -> Bool {
        let before = snapshot
        switch event {
        case .replaceSnapshot(let next):
            try validator.validateSnapshot(next)
            snapshot = next
        case .workspaceUpserted(let workspace):
            snapshot = try upsertWorkspace(workspace)
        case .workspaceClosed(let id):
            snapshot = try closeWorkspace(id)
        case .tabUpserted(let tab):
            snapshot = try upsertTab(tab)
        case .tabClosed(let id):
            snapshot = try closeTab(id)
        case .paneUpserted(let pane):
            snapshot = try upsertPane(pane)
        case .paneClosed(let id):
            snapshot = try closePane(id)
        case .agentUpserted(let agent):
            snapshot = try upsertAgent(agent)
        case .agentClosed(let id):
            snapshot = try closeAgent(id)
        case .focusChanged(let focus):
            snapshot = try replaceFocus(focus)
        case .titleUpdated(let id, let displayTitle):
            snapshot = try updateTitle(id: id, displayTitle: displayTitle)
        case .agentStatusUpdated(let id, let status, let providerRawStatus):
            snapshot = try updateAgentStatus(
                id: id,
                status: status,
                providerRawStatus: providerRawStatus
            )
        }
        return before != snapshot
    }

    private func requireSnapshot() throws -> NestedTopologySnapshot {
        guard let snapshot else {
            throw NestedTopologyValidationError.snapshotRequired
        }
        return snapshot
    }

    private func upsertWorkspace(_ workspace: NestedWorkspaceNode) throws -> NestedTopologySnapshot {
        var current = try requireSnapshot()
        try validator.validateNodeID(workspace.id, expectedKind: .workspace)
        try validator.validateDisplayTitle(workspace.displayTitle)
        var workspaces = current.workspaces.filter { $0.id != workspace.id }
        workspaces.append(workspace)
        if workspaces.count > limits.maxWorkspaces {
            throw NestedTopologyValidationError.countExceeded(
                collection: "workspaces",
                count: workspaces.count,
                limit: limits.maxWorkspaces
            )
        }
        current = rebuilt(from: current, workspaces: workspaces, tabs: current.tabs, panes: current.panes, agents: current.agents, focus: current.focus)
        try validator.validateSnapshot(current)
        return current
    }

    private func closeWorkspace(_ id: NestedNodeID) throws -> NestedTopologySnapshot {
        let current = try requireSnapshot()
        try validator.validateNodeID(id, expectedKind: .workspace)
        guard current.workspace(id: id) != nil else { return current }
        let removedTabIDs = Set(current.tabs.filter { $0.workspaceID == id }.map(\.id))
        let removedPaneIDs = Set(current.panes.filter { removedTabIDs.contains($0.tabID) }.map(\.id))
        let removedAgentIDs = Set(current.agents.filter { removedPaneIDs.contains($0.paneID) }.map(\.id))
        let workspaces = current.workspaces.filter { $0.id != id }
        let tabs = current.tabs.filter { $0.workspaceID != id }
        let panes = current.panes.filter { !removedTabIDs.contains($0.tabID) }
        let agents = current.agents.filter { !removedPaneIDs.contains($0.paneID) }
        let focus = scrubbedFocus(
            current.focus,
            removed: Set([id]).union(removedTabIDs).union(removedPaneIDs).union(removedAgentIDs)
        )
        let next = rebuilt(from: current, workspaces: workspaces, tabs: tabs, panes: panes, agents: agents, focus: focus)
        try validator.validateSnapshot(next)
        return next
    }

    private func upsertTab(_ tab: NestedTabNode) throws -> NestedTopologySnapshot {
        var current = try requireSnapshot()
        try validator.validateNodeID(tab.id, expectedKind: .tab)
        try validator.validateDisplayTitle(tab.displayTitle)
        try validator.validateNodeID(tab.workspaceID, expectedKind: .workspace)
        guard current.workspace(id: tab.workspaceID) != nil else {
            throw NestedTopologyValidationError.malformedParent(
                child: tab.id,
                parent: tab.workspaceID,
                reason: "parent workspace missing"
            )
        }
        var tabs = current.tabs.filter { $0.id != tab.id }
        tabs.append(tab)
        if tabs.count > limits.maxTabs {
            throw NestedTopologyValidationError.countExceeded(
                collection: "tabs",
                count: tabs.count,
                limit: limits.maxTabs
            )
        }
        current = rebuilt(from: current, workspaces: current.workspaces, tabs: tabs, panes: current.panes, agents: current.agents, focus: current.focus)
        try validator.validateSnapshot(current)
        return current
    }

    private func closeTab(_ id: NestedNodeID) throws -> NestedTopologySnapshot {
        let current = try requireSnapshot()
        try validator.validateNodeID(id, expectedKind: .tab)
        guard current.tab(id: id) != nil else { return current }
        let removedPaneIDs = Set(current.panes.filter { $0.tabID == id }.map(\.id))
        let removedAgentIDs = Set(current.agents.filter { removedPaneIDs.contains($0.paneID) }.map(\.id))
        let tabs = current.tabs.filter { $0.id != id }
        let panes = current.panes.filter { $0.tabID != id }
        let agents = current.agents.filter { !removedPaneIDs.contains($0.paneID) }
        let focus = scrubbedFocus(current.focus, removed: Set([id]).union(removedPaneIDs).union(removedAgentIDs))
        let next = rebuilt(from: current, workspaces: current.workspaces, tabs: tabs, panes: panes, agents: agents, focus: focus)
        try validator.validateSnapshot(next)
        return next
    }

    private func upsertPane(_ pane: NestedPaneNode) throws -> NestedTopologySnapshot {
        var current = try requireSnapshot()
        try validator.validateNodeID(pane.id, expectedKind: .pane)
        try validator.validateDisplayTitle(pane.displayTitle)
        try validator.validateNodeID(pane.tabID, expectedKind: .tab)
        guard current.tab(id: pane.tabID) != nil else {
            throw NestedTopologyValidationError.malformedParent(
                child: pane.id,
                parent: pane.tabID,
                reason: "parent tab missing"
            )
        }
        var panes = current.panes.filter { $0.id != pane.id }
        panes.append(pane)
        if panes.count > limits.maxPanes {
            throw NestedTopologyValidationError.countExceeded(
                collection: "panes",
                count: panes.count,
                limit: limits.maxPanes
            )
        }
        current = rebuilt(from: current, workspaces: current.workspaces, tabs: current.tabs, panes: panes, agents: current.agents, focus: current.focus)
        try validator.validateSnapshot(current)
        return current
    }

    private func closePane(_ id: NestedNodeID) throws -> NestedTopologySnapshot {
        let current = try requireSnapshot()
        try validator.validateNodeID(id, expectedKind: .pane)
        guard current.pane(id: id) != nil else { return current }
        let removedAgentIDs = Set(current.agents.filter { $0.paneID == id }.map(\.id))
        let panes = current.panes.filter { $0.id != id }
        let agents = current.agents.filter { $0.paneID != id }
        let focus = scrubbedFocus(current.focus, removed: Set([id]).union(removedAgentIDs))
        let next = rebuilt(from: current, workspaces: current.workspaces, tabs: current.tabs, panes: panes, agents: agents, focus: focus)
        try validator.validateSnapshot(next)
        return next
    }

    private func upsertAgent(_ agent: NestedAgentNode) throws -> NestedTopologySnapshot {
        var current = try requireSnapshot()
        try validator.validateNodeID(agent.id, expectedKind: .agent)
        try validator.validateDisplayTitle(agent.displayTitle)
        try validator.validateAgentStatus(agent.status, providerRawStatus: agent.providerRawStatus)
        try validator.validateNodeID(agent.paneID, expectedKind: .pane)
        guard current.pane(id: agent.paneID) != nil else {
            throw NestedTopologyValidationError.malformedParent(
                child: agent.id,
                parent: agent.paneID,
                reason: "parent pane missing"
            )
        }
        var agents = current.agents.filter { $0.id != agent.id }
        agents.append(agent)
        if agents.count > limits.maxAgents {
            throw NestedTopologyValidationError.countExceeded(
                collection: "agents",
                count: agents.count,
                limit: limits.maxAgents
            )
        }
        current = rebuilt(from: current, workspaces: current.workspaces, tabs: current.tabs, panes: current.panes, agents: agents, focus: current.focus)
        try validator.validateSnapshot(current)
        return current
    }

    private func closeAgent(_ id: NestedNodeID) throws -> NestedTopologySnapshot {
        let current = try requireSnapshot()
        try validator.validateNodeID(id, expectedKind: .agent)
        guard current.agent(id: id) != nil else { return current }
        let agents = current.agents.filter { $0.id != id }
        let focus = scrubbedFocus(current.focus, removed: [id])
        let next = rebuilt(from: current, workspaces: current.workspaces, tabs: current.tabs, panes: current.panes, agents: agents, focus: focus)
        try validator.validateSnapshot(next)
        return next
    }

    private func replaceFocus(_ focus: NestedFocus) throws -> NestedTopologySnapshot {
        let current = try requireSnapshot()
        let kindByID = Dictionary(
            uniqueKeysWithValues:
                current.workspaces.map { ($0.id, NestedNodeKind.workspace) }
                + current.tabs.map { ($0.id, .tab) }
                + current.panes.map { ($0.id, .pane) }
                + current.agents.map { ($0.id, .agent) }
        )
        try validator.validateFocus(focus, kindByID: kindByID)
        let next = rebuilt(
            from: current,
            workspaces: current.workspaces,
            tabs: current.tabs,
            panes: current.panes,
            agents: current.agents,
            focus: focus
        )
        try validator.validateSnapshot(next)
        return next
    }

    private func updateTitle(id: NestedNodeID, displayTitle: String) throws -> NestedTopologySnapshot {
        let current = try requireSnapshot()
        try validator.validateDisplayTitle(displayTitle)
        switch id.kind {
        case .workspace:
            try validator.validateNodeID(id, expectedKind: .workspace)
            guard current.workspace(id: id) != nil else {
                throw NestedTopologyValidationError.unknownNode(id)
            }
            let workspaces = current.workspaces.map { node in
                guard node.id == id else { return node }
                var updated = node
                updated.displayTitle = displayTitle
                return updated
            }
            let next = rebuilt(from: current, workspaces: workspaces, tabs: current.tabs, panes: current.panes, agents: current.agents, focus: current.focus)
            try validator.validateSnapshot(next)
            return next
        case .tab:
            try validator.validateNodeID(id, expectedKind: .tab)
            guard current.tab(id: id) != nil else {
                throw NestedTopologyValidationError.unknownNode(id)
            }
            let tabs = current.tabs.map { node in
                guard node.id == id else { return node }
                var updated = node
                updated.displayTitle = displayTitle
                return updated
            }
            let next = rebuilt(from: current, workspaces: current.workspaces, tabs: tabs, panes: current.panes, agents: current.agents, focus: current.focus)
            try validator.validateSnapshot(next)
            return next
        case .pane:
            try validator.validateNodeID(id, expectedKind: .pane)
            guard current.pane(id: id) != nil else {
                throw NestedTopologyValidationError.unknownNode(id)
            }
            let panes = current.panes.map { node in
                guard node.id == id else { return node }
                var updated = node
                updated.displayTitle = displayTitle
                return updated
            }
            let next = rebuilt(from: current, workspaces: current.workspaces, tabs: current.tabs, panes: panes, agents: current.agents, focus: current.focus)
            try validator.validateSnapshot(next)
            return next
        case .agent:
            try validator.validateNodeID(id, expectedKind: .agent)
            guard current.agent(id: id) != nil else {
                throw NestedTopologyValidationError.unknownNode(id)
            }
            let agents = current.agents.map { node in
                guard node.id == id else { return node }
                var updated = node
                updated.displayTitle = displayTitle
                return updated
            }
            let next = rebuilt(from: current, workspaces: current.workspaces, tabs: current.tabs, panes: current.panes, agents: agents, focus: current.focus)
            try validator.validateSnapshot(next)
            return next
        }
    }

    private func updateAgentStatus(
        id: NestedNodeID,
        status: NestedAgentStatus,
        providerRawStatus: String
    ) throws -> NestedTopologySnapshot {
        let current = try requireSnapshot()
        try validator.validateNodeID(id, expectedKind: .agent)
        try validator.validateAgentStatus(status, providerRawStatus: providerRawStatus)
        guard current.agent(id: id) != nil else {
            throw NestedTopologyValidationError.unknownNode(id)
        }
        let agents = current.agents.map { node in
            guard node.id == id else { return node }
            var updated = node
            updated.status = status
            updated.providerRawStatus = providerRawStatus
            return updated
        }
        let next = rebuilt(
            from: current,
            workspaces: current.workspaces,
            tabs: current.tabs,
            panes: current.panes,
            agents: agents,
            focus: current.focus
        )
        try validator.validateSnapshot(next)
        return next
    }

    private func rebuilt(
        from current: NestedTopologySnapshot,
        workspaces: [NestedWorkspaceNode],
        tabs: [NestedTabNode],
        panes: [NestedPaneNode],
        agents: [NestedAgentNode],
        focus: NestedFocus
    ) -> NestedTopologySnapshot {
        NestedTopologySnapshot(
            encodingVersion: current.encodingVersion,
            attachmentID: current.attachmentID,
            hostStableSurfaceID: current.hostStableSurfaceID,
            provider: current.provider,
            workspaces: workspaces,
            tabs: tabs,
            panes: panes,
            agents: agents,
            focus: focus
        )
    }

    private func scrubbedFocus(_ focus: NestedFocus, removed: Set<NestedNodeID>) -> NestedFocus {
        NestedFocus(
            workspaceID: focus.workspaceID.flatMap { removed.contains($0) ? nil : $0 },
            tabID: focus.tabID.flatMap { removed.contains($0) ? nil : $0 },
            paneID: focus.paneID.flatMap { removed.contains($0) ? nil : $0 },
            agentID: focus.agentID.flatMap { removed.contains($0) ? nil : $0 }
        )
    }
}
