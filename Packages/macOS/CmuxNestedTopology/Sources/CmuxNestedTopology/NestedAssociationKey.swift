/// Identifies one pane/session generation for two-pass parent association.
///
/// The pane ID already carries provider instance and connection generation.
/// An optional provider session value additionally prevents pane reuse from
/// inheriting a prior heuristic lock.
public struct NestedAssociationKey: Codable, Hashable, Sendable {
    /// Compound provider-owned pane identity.
    public let paneID: NestedNodeID

    /// Optional provider agent or conversation session value.
    public let sessionID: String?

    /// Creates a pane/session association key.
    ///
    /// - Parameters:
    ///   - paneID: Compound provider-owned pane identity.
    ///   - sessionID: Optional opaque session value.
    public init(paneID: NestedNodeID, sessionID: String?) {
        self.paneID = paneID
        self.sessionID = sessionID
    }
}
