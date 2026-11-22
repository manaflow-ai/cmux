/// Why New Channel stopped before it asked the owner (``HomeChannelActions``).
public nonisolated enum HomeChannelRefusal: Error, Hashable, Sendable {
    /// A member name matches no teammate, connection or email address.
    case unknownPerson(String)
}
