/// Failures from an explicit vault recovery policy, without private metadata.
public enum MobileRemoteVaultRecoveryError: Error, Equatable, Sendable {
    /// An organization identifier is empty, oversized, ambiguous, or contains controls.
    case invalidOrganization
    /// Organization recovery cannot be added to a personal vault.
    case organizationRecoveryRequiresTeam
}
