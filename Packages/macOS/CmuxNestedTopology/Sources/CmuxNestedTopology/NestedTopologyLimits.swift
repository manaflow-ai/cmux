/// Resource bounds enforced by ``NestedTopologyReducer``.
///
/// Oversized snapshots and events fail deterministically instead of growing without bound.
public struct NestedTopologyLimits: Hashable, Codable, Sendable {
    /// Maximum workspace nodes in one snapshot.
    public var maxWorkspaces: Int
    /// Maximum tab nodes in one snapshot.
    public var maxTabs: Int
    /// Maximum pane nodes in one snapshot.
    public var maxPanes: Int
    /// Maximum agent nodes in one snapshot.
    public var maxAgents: Int
    /// Maximum depth from workspace root (workspace=0 … agent=3).
    public var maxDepth: Int
    /// Maximum UTF-8 byte length of an opaque provider raw ID.
    public var maxRawIDUTF8ByteCount: Int
    /// Maximum UTF-8 byte length of a display title.
    public var maxDisplayTitleUTF8ByteCount: Int
    /// Maximum UTF-8 byte length of a provider raw status string.
    public var maxProviderRawStatusUTF8ByteCount: Int
    /// Maximum UTF-8 byte length of a provider instance ID.
    public var maxProviderInstanceIDUTF8ByteCount: Int
    /// Maximum UTF-8 byte length of a provider version string.
    public var maxProviderVersionUTF8ByteCount: Int
    /// Maximum nesting depth for a Herdr layout tree (leaf depth 0).
    public var maxLayoutTreeDepth: Int

    /// Default production limits for nested topology ingestion.
    public static let `default` = NestedTopologyLimits(
        maxWorkspaces: 64,
        maxTabs: 256,
        maxPanes: 1_024,
        maxAgents: 1_024,
        maxDepth: NestedNodeKind.agent.depth,
        maxRawIDUTF8ByteCount: 256,
        maxDisplayTitleUTF8ByteCount: 512,
        maxProviderRawStatusUTF8ByteCount: 64,
        maxProviderInstanceIDUTF8ByteCount: 128,
        maxProviderVersionUTF8ByteCount: 64,
        maxLayoutTreeDepth: 64
    )

    /// Creates topology limits.
    public init(
        maxWorkspaces: Int,
        maxTabs: Int,
        maxPanes: Int,
        maxAgents: Int,
        maxDepth: Int,
        maxRawIDUTF8ByteCount: Int,
        maxDisplayTitleUTF8ByteCount: Int,
        maxProviderRawStatusUTF8ByteCount: Int,
        maxProviderInstanceIDUTF8ByteCount: Int,
        maxProviderVersionUTF8ByteCount: Int,
        maxLayoutTreeDepth: Int = 64
    ) {
        self.maxWorkspaces = maxWorkspaces
        self.maxTabs = maxTabs
        self.maxPanes = maxPanes
        self.maxAgents = maxAgents
        self.maxDepth = maxDepth
        self.maxRawIDUTF8ByteCount = maxRawIDUTF8ByteCount
        self.maxDisplayTitleUTF8ByteCount = maxDisplayTitleUTF8ByteCount
        self.maxProviderRawStatusUTF8ByteCount = maxProviderRawStatusUTF8ByteCount
        self.maxProviderInstanceIDUTF8ByteCount = maxProviderInstanceIDUTF8ByteCount
        self.maxProviderVersionUTF8ByteCount = maxProviderVersionUTF8ByteCount
        self.maxLayoutTreeDepth = maxLayoutTreeDepth
    }
}
