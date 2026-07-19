/// The authority that admitted one control-socket command.
///
/// Callers can make line-scoped policy decisions from this value without
/// inferring trust from the presence of a syntactically valid envelope.
public enum SocketClientAuthorizationBasis: Sendable, Equatable {
    /// The peer currently belongs to cmux's trusted process tree.
    case descendant

    /// The command carried a capability verified by the current authority.
    case verifiedCapability

    /// The socket peer has the same effective user ID as cmux.
    case sameOwner

    /// The active socket mode permits clients without identity restrictions.
    case unrestricted
}
