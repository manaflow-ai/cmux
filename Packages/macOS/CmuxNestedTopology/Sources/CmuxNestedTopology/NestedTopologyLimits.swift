/// Resource limits applied before a nested topology can be published.
public struct NestedTopologyLimits: Equatable, Sendable {
    /// Maximum workspace nodes.
    public let maximumWorkspaces: Int

    /// Maximum tab nodes.
    public let maximumTabs: Int

    /// Maximum pane nodes.
    public let maximumPanes: Int

    /// Maximum agent nodes.
    public let maximumAgents: Int

    /// Maximum nodes across every level.
    public let maximumTotalNodes: Int

    /// Maximum provider events accepted in one atomic batch.
    public let maximumEventsPerBatch: Int

    /// Maximum accepted one-based hierarchy depth.
    public let maximumDepth: Int

    /// Maximum UTF-8 bytes for provider and node identifiers.
    public let maximumIdentifierBytes: Int

    /// Maximum UTF-8 bytes for a display title.
    public let maximumTitleBytes: Int

    /// Maximum UTF-8 bytes for the original provider status.
    public let maximumRawStatusBytes: Int

    /// Maximum UTF-8 bytes for an optional provider session value.
    public let maximumSessionIDBytes: Int

    /// Maximum distinct provider capabilities.
    public let maximumCapabilities: Int

    /// Maximum UTF-8 bytes for one semantic capability token.
    public let maximumCapabilityBytes: Int

    /// Creates topology resource limits with production defaults for omitted values.
    ///
    /// Nonpositive limits are rejected by the reducer before inspecting input.
    ///
    /// - Parameters:
    ///   - maximumWorkspaces: Maximum workspace nodes.
    ///   - maximumTabs: Maximum tab nodes.
    ///   - maximumPanes: Maximum pane nodes.
    ///   - maximumAgents: Maximum agent nodes.
    ///   - maximumTotalNodes: Maximum total nodes.
    ///   - maximumEventsPerBatch: Maximum events in one atomic batch.
    ///   - maximumDepth: Maximum one-based hierarchy depth.
    ///   - maximumIdentifierBytes: Maximum identifier bytes.
    ///   - maximumTitleBytes: Maximum display-title bytes.
    ///   - maximumRawStatusBytes: Maximum raw-status bytes.
    ///   - maximumSessionIDBytes: Maximum session-value bytes.
    ///   - maximumCapabilities: Maximum distinct capabilities.
    ///   - maximumCapabilityBytes: Maximum capability-token bytes.
    public init(
        maximumWorkspaces: Int = 128,
        maximumTabs: Int = 512,
        maximumPanes: Int = 2_048,
        maximumAgents: Int = 2_048,
        maximumTotalNodes: Int = 4_096,
        maximumEventsPerBatch: Int = 4_096,
        maximumDepth: Int = 4,
        maximumIdentifierBytes: Int = 1_024,
        maximumTitleBytes: Int = 4_096,
        maximumRawStatusBytes: Int = 256,
        maximumSessionIDBytes: Int = 1_024,
        maximumCapabilities: Int = 128,
        maximumCapabilityBytes: Int = 256
    ) {
        self.maximumWorkspaces = maximumWorkspaces
        self.maximumTabs = maximumTabs
        self.maximumPanes = maximumPanes
        self.maximumAgents = maximumAgents
        self.maximumTotalNodes = maximumTotalNodes
        self.maximumEventsPerBatch = maximumEventsPerBatch
        self.maximumDepth = maximumDepth
        self.maximumIdentifierBytes = maximumIdentifierBytes
        self.maximumTitleBytes = maximumTitleBytes
        self.maximumRawStatusBytes = maximumRawStatusBytes
        self.maximumSessionIDBytes = maximumSessionIDBytes
        self.maximumCapabilities = maximumCapabilities
        self.maximumCapabilityBytes = maximumCapabilityBytes
    }
}
