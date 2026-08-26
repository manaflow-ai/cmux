/// Trusted cmux-owned title lock applied outside the provider event path.
public enum NestedTopologyTitleChange: Equatable, Sendable {
    /// Locks one node title to a host-surface policy value.
    case host(nodeID: NestedNodeID, value: String)

    /// Locks one node title to an explicit user-owned value.
    case user(nodeID: NestedNodeID, value: String)

    /// Target compound node identity.
    var nodeID: NestedNodeID {
        switch self {
        /// Extracts the common target from either trusted change kind.
        case let .host(nodeID, _), let .user(nodeID, _):
            nodeID
        }
    }

    /// Validated title value represented by this trusted change.
    var title: NestedNodeTitle {
        switch self {
        /// Projects a host-owned change into published title state.
        case let .host(_, value):
            NestedNodeTitle(value: value, authority: .host)
        /// Projects a user-owned change into published title state.
        case let .user(_, value):
            NestedNodeTitle(value: value, authority: .user)
        }
    }
}
