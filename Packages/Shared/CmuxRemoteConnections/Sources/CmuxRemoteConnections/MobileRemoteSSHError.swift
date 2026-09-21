/// Failures from the account and host-trust SSH boundary.
public enum MobileRemoteSSHError: Error, Equatable, Sendable {
    /// The selected session needs its own carrier adapter.
    case unsupportedCarrier(MobileRemoteCarrier)
    /// The engine supplied malformed, missing, or wrong-profile key material.
    case invalidHostKeyChallenge
    /// The user or trusted-host store refused the current server key.
    case hostKeyRejected
}
