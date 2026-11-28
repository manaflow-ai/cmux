/// A local host-policy cache validation failure that contains no account or credential data.
public enum CmxIrohHostPolicyCacheError: Error, Equatable, Sendable {
    /// The caller supplied a malformed account, installation, or endpoint expectation.
    case invalidExpectation

    /// The policy cannot safely authorize an offline Mac host.
    case invalidPolicy

    /// The cached policy does not match the caller's current local identity and settings.
    case policyMismatch

    /// The broker envelope expiry does not match the signed attestation expiry.
    case invalidAttestationEnvelope
}
