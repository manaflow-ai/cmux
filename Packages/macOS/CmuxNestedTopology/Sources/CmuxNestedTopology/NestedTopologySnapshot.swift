/// Validated immutable provider-owned topology snapshot.
///
/// The snapshot deliberately contains no cmux workspace, Bonsplit pane,
/// Ghostty surface, endpoint, or persistence identity. A later attachment
/// layer binds this virtual tree to a host stable surface.
public struct NestedTopologySnapshot: Codable, Equatable, Sendable {
    /// Provider instance and connection generation that own every node.
    public let provider: NestedProviderIdentity

    /// Negotiated semantic provider capabilities.
    public let capabilities: NestedProviderCapabilities

    /// Provider workspaces in deterministic order.
    public let workspaces: [NestedWorkspaceNode]

    /// Provider tabs in deterministic sibling order.
    public let tabs: [NestedTabNode]

    /// Provider panes in deterministic sibling order.
    public let panes: [NestedPaneNode]

    /// Provider agents in deterministic sibling order.
    public let agents: [NestedAgentNode]

    /// One coherent focused path.
    public let focus: NestedTopologyFocus

    /// Validates and creates an immutable topology snapshot.
    ///
    /// - Parameters:
    ///   - provider: Provider identity shared by all nodes.
    ///   - capabilities: Negotiated semantic capabilities.
    ///   - workspaces: Provider workspace values.
    ///   - tabs: Provider tab values.
    ///   - panes: Provider pane values.
    ///   - agents: Provider agent values.
    ///   - focus: Focused virtual path.
    ///   - limits: Resource limits applied before publication.
    /// - Throws: ``NestedTopologyError`` when input is inconsistent or unbounded.
    public init(
        provider: NestedProviderIdentity,
        capabilities: NestedProviderCapabilities,
        workspaces: [NestedWorkspaceNode],
        tabs: [NestedTabNode],
        panes: [NestedPaneNode],
        agents: [NestedAgentNode],
        focus: NestedTopologyFocus,
        limits: NestedTopologyLimits = .standard
    ) throws {
        self = try NestedTopologyReducer(limits: limits).makeSnapshot(
            provider: provider,
            capabilities: capabilities,
            workspaces: workspaces,
            tabs: tabs,
            panes: panes,
            agents: agents,
            focus: focus
        )
    }

    init(
        validatedProvider provider: NestedProviderIdentity,
        capabilities: NestedProviderCapabilities,
        workspaces: [NestedWorkspaceNode],
        tabs: [NestedTabNode],
        panes: [NestedPaneNode],
        agents: [NestedAgentNode],
        focus: NestedTopologyFocus
    ) {
        self.provider = provider
        self.capabilities = capabilities
        self.workspaces = workspaces
        self.tabs = tabs
        self.panes = panes
        self.agents = agents
        self.focus = focus
    }

    /// Decodes and validates a snapshot with standard publication limits.
    ///
    /// - Parameter decoder: Decoder containing the snapshot fields.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self = try NestedTopologyReducer().makeSnapshot(
            provider: container.decode(NestedProviderIdentity.self, forKey: .provider),
            capabilities: container.decode(NestedProviderCapabilities.self, forKey: .capabilities),
            workspaces: container.decode([NestedWorkspaceNode].self, forKey: .workspaces),
            tabs: container.decode([NestedTabNode].self, forKey: .tabs),
            panes: container.decode([NestedPaneNode].self, forKey: .panes),
            agents: container.decode([NestedAgentNode].self, forKey: .agents),
            focus: container.decode(NestedTopologyFocus.self, forKey: .focus)
        )
    }

    /// Encodes the validated immutable snapshot.
    ///
    /// - Parameter encoder: Encoder receiving the snapshot fields.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(provider, forKey: .provider)
        try container.encode(capabilities, forKey: .capabilities)
        try container.encode(workspaces, forKey: .workspaces)
        try container.encode(tabs, forKey: .tabs)
        try container.encode(panes, forKey: .panes)
        try container.encode(agents, forKey: .agents)
        try container.encode(focus, forKey: .focus)
    }

    private enum CodingKeys: String, CodingKey {
        case provider
        case capabilities
        case workspaces
        case tabs
        case panes
        case agents
        case focus
    }
}
