/// Bounded failures from vault membership authentication, without private metadata.
public enum MobileRemoteVaultManifestError: Error, Equatable, Sendable {
    /// The manifest has invalid bounds, version, or chain metadata.
    case invalidManifest
    /// A participant has invalid account or public-key metadata.
    case invalidParticipant
    /// Device identities or public keys are repeated across participants.
    case duplicateParticipant
    /// At least one active owner is required.
    case missingOwner
    /// Organization recovery has no matching team policy and public key.
    case invalidRecoveryRecipient
    /// The manifest does not match the independently expected vault context.
    case contextMismatch
    /// An initial manifest does not match the digest approved outside the server.
    case untrustedAnchor
    /// The update is not the immediate successor of the accepted manifest.
    case brokenChain
    /// The signer was not an active owner in the previously trusted membership.
    case signerNotAuthorized
    /// The signature does not authenticate the manifest content.
    case invalidSignature
    /// Removing access or replacing keys requires advancing the vault key epoch.
    case keyRotationRequired
    /// The key epoch decreases or skips a generation.
    case invalidEpochTransition
    /// Key delivery does not match an active owner and approved recipient.
    case envelopeNotAuthorized
}
