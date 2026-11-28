/// Failures at the account-private LAN discovery alias boundary.
public enum CmxIrohLANRendezvousAliasError: Error, Equatable, Sendable {
    case invalidKey
    case invalidTimestamp
    case unsupportedPlatform
}
