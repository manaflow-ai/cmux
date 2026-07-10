/// Validation failures for Iroh path hints.
public enum CmxIrohPathHintError: Error, Equatable, Sendable {
    /// The hint carried no address or relay value.
    case emptyValue
    /// The provider and privacy scope describe incompatible networks.
    case incompatiblePrivacyScope(
        source: CmxIrohPathHintSource,
        scope: CmxIrohPathHintPrivacyScope
    )
    /// A newly created private hint omitted its required expiry.
    case missingPrivateHintExpiry
    /// A direct hint was not an IPv4-or-bracketed-IPv6 socket address.
    case invalidDirectAddress
    /// A direct hint targeted a non-peer address such as loopback or multicast.
    case forbiddenDirectAddress
    /// A direct hint claimed public scope for a non-globally-routable address.
    case nonGlobalPublicDirectAddress
    /// A relay identifier contained unsafe or ambiguous characters.
    case invalidRelayIdentifier
    /// A relay URL was not a root HTTPS URL without credentials or query data.
    case unsafeRelayURL
    /// An optional network profile identifier was empty or malformed.
    case invalidNetworkProfileID
}
