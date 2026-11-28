/// Non-secret reason a requested relay preference could not become effective.
public enum CmxIrohRelayPolicyFailure: String, Codable, Equatable, Sendable {
    /// No signed managed policy is available.
    case policyUnavailable

    /// The cached or broker policy has expired.
    case policyExpired

    /// The broker policy failed signature or schema validation.
    case policyRejected

    /// The broker policy attempted a sequence rollback or equivocation.
    case policyRollback

    /// Every requested managed relay identifier disappeared from the policy.
    case staleManagedSelection

    /// At least one custom relay requires a token that is absent on this device.
    case missingCustomCredential

    /// Secure storage for custom relay tokens could not be read.
    case customCredentialUnavailable

    /// The broker attempted a preference revision rollback or equivocation.
    case preferenceRollback

    /// The server committed an account change that this device could not cache.
    case preferencePersistenceUnavailable

    /// The signed managed allowlist is active without a usable current token.
    case managedCredentialUnavailable
}
