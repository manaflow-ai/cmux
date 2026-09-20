public import Foundation

/// Result of applying one authenticated encrypted record.
public enum MobileRemoteVaultMergeResult: Equatable, Sendable {
    /// The record is newer than local state and is now authoritative.
    case applied
    /// The exact signed record was already accepted.
    case duplicate
}

/// Authenticated merge policy for one personal or team vault.
///
/// This actor accepts ciphertext only after checking membership, writer role,
/// account/vault/epoch binding, and the signature over the exact sealed record.
/// It does not persist its state or decrypt payloads. The eventual sync store
/// must persist accepted revisions and its anti-rollback watermark atomically
/// with the encrypted record.
public actor MobileRemoteVaultMergePolicy {
    private struct Accepted: Equatable, Sendable {
        let revision: Int64
        let kind: MobileRemoteVaultRecordKind
        let digest: Data
        let deleted: Bool
        let writerDeviceID: UUID
    }

    private let accountID: String
    private let vaultID: UUID
    private let keyEpoch: Int64
    private let members: [UUID: MobileRemoteVaultMember]
    private var accepted: [UUID: Accepted] = [:]

    /// Creates a policy over an authenticated membership snapshot.
    ///
    /// - Parameters:
    ///   - accountID: Expected vault owner account.
    ///   - vaultID: Expected vault identity.
    ///   - keyEpoch: Only this current epoch may write new records.
    ///   - members: Authenticated device membership, never server-supplied ad hoc.
    /// - Throws: Invalid context or duplicate/invalid membership errors.
    public init(
        accountID: String,
        vaultID: UUID,
        keyEpoch: Int64,
        members: [MobileRemoteVaultMember]
    ) throws {
        guard !accountID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              accountID.utf8.count <= 256,
              !accountID.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              keyEpoch > 0 else {
            throw MobileRemoteVaultMergeError.invalidContext
        }
        var byID: [UUID: MobileRemoteVaultMember] = [:]
        for member in members {
            guard byID.updateValue(member, forKey: member.deviceID) == nil else {
                throw MobileRemoteVaultMergeError.duplicateMember
            }
        }
        self.accountID = accountID
        self.vaultID = vaultID
        self.keyEpoch = keyEpoch
        self.members = byID
    }

    /// Applies one signed record after independently validating its envelope.
    ///
    /// - Parameters:
    ///   - envelope: Bounded encrypted record.
    ///   - revision: Signed metadata for that exact record.
    /// - Returns: Applied or idempotent duplicate.
    /// - Throws: Membership, stale, conflict, context, or signature errors.
    public func apply(
        envelope: MobileRemoteVaultEnvelope,
        revision: MobileRemoteVaultRevision
    ) throws -> MobileRemoteVaultMergeResult {
        guard revision.accountID == accountID,
              revision.vaultID == vaultID,
              revision.keyEpoch == keyEpoch else {
            throw MobileRemoteVaultMergeError.contextMismatch
        }
        guard let member = members[revision.writerDeviceID],
              !member.revoked,
              member.keyEpoch <= keyEpoch,
              member.role == .owner || member.role == .editor else {
            throw MobileRemoteVaultMergeError.writerNotAuthorized
        }
        let context = try MobileRemoteVaultContext(
            accountID: accountID,
            vaultID: vaultID,
            recordID: revision.recordID,
            kind: revision.kind,
            keyEpoch: revision.keyEpoch,
            revision: revision.revision,
            deleted: revision.deleted
        )
        do {
            try revision.verify(
                envelope: envelope,
                context: context,
                writerDeviceID: member.deviceID,
                using: try member.signingKey()
            )
        } catch MobileRemoteVaultError.invalidSignature {
            throw MobileRemoteVaultMergeError.invalidSignature
        } catch {
            throw MobileRemoteVaultMergeError.invalidMember
        }
        let digest = MobileRemoteVaultRevision.digest(of: envelope)
        if let previous = accepted[revision.recordID] {
            if revision.revision < previous.revision {
                throw MobileRemoteVaultMergeError.staleRevision
            }
            if revision.revision == previous.revision {
                guard previous.kind == revision.kind,
                      previous.digest == digest,
                      previous.deleted == revision.deleted,
                      previous.writerDeviceID == revision.writerDeviceID else {
                    throw MobileRemoteVaultMergeError.conflictingRevision
                }
                return .duplicate
            }
        }
        accepted[revision.recordID] = Accepted(
            revision: revision.revision, kind: revision.kind, digest: digest,
            deleted: revision.deleted, writerDeviceID: revision.writerDeviceID
        )
        return .applied
    }

    /// Returns the accepted revision watermark for one record.
    public func revision(for recordID: UUID) -> Int64? {
        accepted[recordID]?.revision
    }

    /// Returns whether the accepted record is an authenticated tombstone.
    public func isDeleted(recordID: UUID) -> Bool {
        accepted[recordID]?.deleted == true
    }
}

/// Failures from authenticated encrypted-record merge.
public enum MobileRemoteVaultMergeError: Error, Equatable, Sendable {
    /// Account, vault, or positive epoch metadata is malformed.
    case invalidContext
    /// A device member has an invalid key, epoch, or identifier.
    case invalidMember
    /// A membership snapshot repeats a device identity.
    case duplicateMember
    /// Record metadata does not match this policy's scope or epoch.
    case contextMismatch
    /// The trusted member key did not authenticate the exact record.
    case invalidSignature
    /// The writer is missing, revoked, viewer-only, or recovery-only.
    case writerNotAuthorized
    /// The incoming revision is older than accepted state.
    case staleRevision
    /// Same record and revision carry different authenticated content.
    case conflictingRevision
}
