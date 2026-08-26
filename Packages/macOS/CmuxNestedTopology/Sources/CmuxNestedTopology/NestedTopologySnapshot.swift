import Foundation

/// Validated immutable provider-owned topology snapshot.
///
/// The snapshot deliberately contains no cmux workspace, Bonsplit pane,
/// Ghostty surface, endpoint, or persistence identity. A later attachment
/// layer binds this virtual tree to a host stable surface.
/// Equality includes the validation policy that certified the snapshot because
/// reducers use that policy to decide whether the topology must be revalidated.
/// The policy remains local trust metadata and is not encoded on the wire.
public struct NestedTopologySnapshot: Codable, Equatable, Sendable {
    /// Decoder user-info key for a caller-owned ``NestedTopologyLimits`` value.
    ///
    /// Decoding uses a default ``NestedTopologyLimits`` value when this key is absent.
    /// A caller that encoded a snapshot accepted under custom limits should put
    /// the same limits in `JSONDecoder.userInfo` before decoding.
    public static let decodingLimitsUserInfoKey = CodingUserInfoKey(
        rawValue: "com.cmux.nested-topology.decoding-limits"
    )!

    /// Decoder user-info key for an explicit ``NestedTopologySnapshotDecodingMode`` value.
    ///
    /// Decoding defaults to ``NestedTopologySnapshotDecodingMode/providerInput``. Only cmux-owned
    /// serialization of an already-published snapshot may opt in to
    /// ``NestedTopologySnapshotDecodingMode/trustedPublishedSnapshot`` so provider data cannot claim
    /// host or user title authority.
    public static let decodingModeUserInfoKey = CodingUserInfoKey(
        rawValue: "com.cmux.nested-topology.decoding-mode"
    )!

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

    /// Trust policy that certified this immutable snapshot.
    let validationLimits: NestedTopologyLimits

    /// Stable indexes reused by incremental reducers.
    let lookup: NestedTopologyLookup

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
        limits: NestedTopologyLimits = NestedTopologyLimits()
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
        focus: NestedTopologyFocus,
        validationLimits: NestedTopologyLimits,
        lookup: NestedTopologyLookup? = nil
    ) {
        self.provider = provider
        self.capabilities = capabilities
        self.workspaces = workspaces
        self.tabs = tabs
        self.panes = panes
        self.agents = agents
        self.focus = focus
        self.validationLimits = validationLimits
        self.lookup = lookup ?? NestedTopologyLookup(
            workspaces: workspaces,
            tabs: tabs,
            panes: panes,
            agents: agents
        )
    }

    /// Decodes and incrementally validates a snapshot with caller-supplied limits.
    ///
    /// Decoder APIs do not expose the source byte count. Provider transports
    /// must enforce a bounded frame size before constructing their decoder.
    ///
    /// - Parameter decoder: Decoder containing the snapshot fields.
    public init(from decoder: any Decoder) throws {
        let limits = decoder.userInfo[Self.decodingLimitsUserInfoKey]
            as? NestedTopologyLimits ?? NestedTopologyLimits()
        let mode = decoder.userInfo[Self.decodingModeUserInfoKey]
            as? NestedTopologySnapshotDecodingMode ?? .providerInput
        self = try NestedTopologySnapshotDecoder(limits: limits, mode: mode).decode(from: decoder)
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

    enum CodingKeys: String, CodingKey {
        case provider
        case capabilities
        case workspaces
        case tabs
        case panes
        case agents
        case focus
    }
}
