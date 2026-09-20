public import Foundation

/// Verifies membership authority without trusting server-supplied participant lists.
///
/// Genesis requires a digest approved through an authenticated device/user
/// channel. Updates require the exact previously accepted manifest and a signature
/// from one of its active owners. This value does not persist the chain, detect
/// forks withheld from different devices, or execute key rotation.
public struct MobileRemoteVaultManifestVerifier: Sendable {
    /// Creates a stateless membership verifier.
    public init() {}

    /// Authenticates the first manifest against an independently approved digest.
    ///
    /// Never obtain `approvedDigest` solely from the server delivering `manifest`.
    /// A new device must receive it from its trusted approval channel, then verify
    /// the complete successor chain to the current state.
    /// - Parameters:
    ///   - manifest: Received initial manifest.
    ///   - accountID: Expected stable vault namespace account.
    ///   - vaultID: Expected vault identifier.
    ///   - scope: Expected personal or exact organization boundary.
    ///   - approvedDigest: SHA-256 body digest approved outside the sync server.
    /// - Returns: Authenticated genesis membership.
    /// - Throws: Context, anchor, signer authority, or signature errors.
    public func verifyGenesis(
        _ manifest: MobileRemoteVaultManifest,
        accountID: String,
        vaultID: UUID,
        scope: MobileRemoteVaultScope,
        approvedDigest: Data
    ) throws -> MobileRemoteTrustedVaultManifest {
        guard manifest.accountID == accountID, manifest.vaultID == vaultID,
              manifest.recoveryPolicy.scope == scope else {
            throw MobileRemoteVaultManifestError.contextMismatch
        }
        guard manifest.revision == 1, manifest.keyEpoch == 1,
              manifest.previousDigest == nil,
              approvedDigest.count == 32, manifest.digest == approvedDigest else {
            throw MobileRemoteVaultManifestError.untrustedAnchor
        }
        try verifyOwnerSignature(manifest, authorizedBy: manifest)
        return MobileRemoteTrustedVaultManifest(verified: manifest)
    }

    /// Verifies an immediate successor using the previously accepted owners.
    /// - Parameters:
    ///   - manifest: Received successor proposal.
    ///   - previous: Last accepted state, never reconstructed from unverified JSON.
    /// - Returns: Authenticated successor; persist it before authorizing new work.
    /// - Throws: Context, chain, authority, signature, or required-rotation errors.
    public func verifySuccessor(
        _ manifest: MobileRemoteVaultManifest,
        after previous: MobileRemoteTrustedVaultManifest
    ) throws -> MobileRemoteTrustedVaultManifest {
        let old = previous.manifest
        guard manifest.accountID == old.accountID, manifest.vaultID == old.vaultID,
              manifest.recoveryPolicy.scope == old.recoveryPolicy.scope else {
            throw MobileRemoteVaultManifestError.contextMismatch
        }
        guard old.revision < Int64.max, manifest.revision == old.revision + 1,
              manifest.previousDigest == old.digest else {
            throw MobileRemoteVaultManifestError.brokenChain
        }
        try verifyOwnerSignature(manifest, authorizedBy: old)
        let sameEpoch = manifest.keyEpoch == old.keyEpoch
        let nextEpoch = old.keyEpoch < Int64.max && manifest.keyEpoch == old.keyEpoch + 1
        guard sameEpoch || nextEpoch else {
            throw MobileRemoteVaultManifestError.invalidEpochTransition
        }
        if sameEpoch, removesAuthority(manifest, from: old) {
            throw MobileRemoteVaultManifestError.keyRotationRequired
        }
        return MobileRemoteTrustedVaultManifest(verified: manifest)
    }

    private func verifyOwnerSignature(
        _ manifest: MobileRemoteVaultManifest,
        authorizedBy previous: MobileRemoteVaultManifest
    ) throws {
        guard let signer = previous.participants.first(where: {
            $0.member.deviceID == manifest.signerDeviceID
        }), !signer.member.revoked, signer.member.role == .owner else {
            throw MobileRemoteVaultManifestError.signerNotAuthorized
        }
        try manifest.verifySignature(using: signer.member.signingKey())
    }

    /// Previously disclosed keys cannot be clawed back; removals change future keys.
    private func removesAuthority(_ next: MobileRemoteVaultManifest, from old: MobileRemoteVaultManifest) -> Bool {
        let byID = Dictionary(uniqueKeysWithValues: next.participants.map { ($0.member.deviceID, $0) })
        for previous in old.participants where !previous.member.revoked {
            guard let current = byID[previous.member.deviceID], !current.member.revoked,
                  previous.accountID == current.accountID,
                  previous.member.signingPublicKey == current.member.signingPublicKey,
                  previous.encryptionPublicKey == current.encryptionPublicKey,
                  accessLevel(current.member.role) >= accessLevel(previous.member.role) else { return true }
        }
        if old.recoveryPolicy.organizationRecoveryKeyID != nil {
            return old.recoveryPolicy.organizationRecoveryKeyID != next.recoveryPolicy.organizationRecoveryKeyID
                || old.organizationRecoveryPublicKey != next.organizationRecoveryPublicKey
        }
        return false
    }

    private func accessLevel(_ role: MobileRemoteVaultMemberRole) -> Int {
        switch role {
        case .owner: 3
        case .editor: 2
        case .viewer: 1
        case .recovery: 0
        }
    }
}
