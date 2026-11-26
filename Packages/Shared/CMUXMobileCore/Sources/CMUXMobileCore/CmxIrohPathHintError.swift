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
    /// A newly created non-public hint omitted the time it was observed.
    case missingPrivateHintObservation
    /// A non-public hint's expiry did not follow its observation time.
    case invalidPrivateHintLifetime
    /// A non-public hint exceeded the maximum one-hour lifetime.
    case privateHintTTLExceedsMaximum
    /// A non-public hint omitted its provider-qualified network profile.
    case missingPrivateHintNetworkProfile
    /// A hint used a profile owned by a different provider.
    case networkProfileSourceMismatch
    /// A public hint carried private-network profile metadata.
    case unexpectedPublicNetworkProfile
    /// Relay hints must come from Iroh-native public discovery.
    case relayHintRequiresNativePublicSource
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
}
