/// One accepted projection-navigation command or list page.
public struct BackendProjectionNavigationApplied: Codable, Equatable, Sendable {
    /// The exact canonical topology revision used to validate and reconcile the command.
    public let topologyRevision: UInt64

    /// The stable client's list-snapshot revision, present only on list pages.
    public let clientRevision: UInt64?

    /// The continuation cursor is intentionally module-private so callers
    /// cannot persist or fabricate daemon list-snapshot authority.
    let nextCursor: BackendProjectionNavigationListCursor?

    /// Claimed, changed, or listed logical-window records.
    public let states: [BackendProjectionNavigationState]

    /// Creates one applied response payload.
    ///
    /// - Parameters:
    ///   - topologyRevision: The exact topology revision used by the daemon.
    ///   - clientRevision: The list-snapshot revision, for list pages.
    ///   - states: The response's logical-window records.
    public init(
        topologyRevision: UInt64,
        clientRevision: UInt64? = nil,
        states: [BackendProjectionNavigationState]
    ) {
        self.topologyRevision = topologyRevision
        self.clientRevision = clientRevision
        nextCursor = nil
        self.states = states
    }

    private enum CodingKeys: String, CodingKey {
        case topologyRevision = "topology_revision"
        case clientRevision = "client_revision"
        case nextCursor = "next_cursor"
        case states
    }
}
