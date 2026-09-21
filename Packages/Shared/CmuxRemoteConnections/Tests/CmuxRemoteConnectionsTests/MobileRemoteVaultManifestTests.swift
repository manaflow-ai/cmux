import CryptoKit
import Foundation
import Testing
@testable import CmuxRemoteConnections

@Suite struct MobileRemoteVaultManifestTests {
    @Test(arguments: [false, true])
    func authenticatesPersonalAndTeamGenesis(team: Bool) throws {
        let fixture = try Fixture(team: team)
        let encoded = try JSONEncoder().encode(fixture.genesis)
        let decoded = try JSONDecoder().decode(MobileRemoteVaultManifest.self, from: encoded)
        let verified = try fixture.trust(decoded)
        #expect(verified.manifest.digest == fixture.genesis.digest)
        #expect(verified.manifest.participants.count == 2)
    }

    @Test func aServerCannotSubstituteItsOwnSelfSignedGenesis() throws {
        let fixture = try Fixture()
        let attacker = Curve25519.Signing.PrivateKey()
        let substituteOwner = try fixture.participant(id: fixture.ownerID, role: .owner, signingKey: attacker)
        let substitute = try fixture.proposal(participants: [substituteOwner]).signed(by: attacker)
        #expect(throws: MobileRemoteVaultManifestError.untrustedAnchor) { try fixture.trust(substitute) }
        #expect(throws: MobileRemoteVaultManifestError.invalidSignature) {
            try fixture.trust(fixture.proposal(participants: fixture.genesis.participants))
        }
    }

    @Test func canonicalMembershipOrderAndResigningKeepDigest() throws {
        let fixture = try Fixture()
        let reordered = try fixture.proposal(participants: fixture.genesis.participants.reversed())
            .signed(by: fixture.ownerKey)
        #expect(reordered.digest == fixture.genesis.digest)
        #expect(try fixture.trust(reordered).manifest.digest == fixture.genesis.digest)
    }

    @Test func ownerCanEnrollAnAdditionalTeamAccount() throws {
        let fixture = try Fixture(team: true)
        let trusted = try fixture.trust(fixture.genesis)
        let newDevice = try fixture.participant(id: UUID(), role: .viewer, account: "third-account")
        let next = try fixture.successor(participants: fixture.genesis.participants + [newDevice])
        let accepted = try fixture.verifier.verifySuccessor(next, after: trusted)
        #expect(accepted.manifest.revision == 2)
        #expect(accepted.manifest.participants.contains(newDevice))
    }

    @Test(arguments: [MobileRemoteVaultMemberRole.editor, .viewer, .recovery])
    func nonOwnerCannotPromoteItself(role: MobileRemoteVaultMemberRole) throws {
        let fixture = try Fixture(team: true, peerRole: role)
        let trusted = try fixture.trust(fixture.genesis)
        let promoted = try fixture.peer(role: .owner)
        let next = try fixture.successor(
            participants: [fixture.owner, promoted], signer: fixture.peerID, key: fixture.peerKey
        )
        #expect(throws: MobileRemoteVaultManifestError.signerNotAuthorized) {
            try fixture.verifier.verifySuccessor(next, after: trusted)
        }
    }

    @Test func candidateKeyCannotReplaceThePreviousOwnersVerificationKey() throws {
        let fixture = try Fixture()
        let attacker = Curve25519.Signing.PrivateKey()
        let replacement = try fixture.participant(id: fixture.ownerID, role: .owner, signingKey: attacker)
        let next = try fixture.successor(participants: [replacement], key: attacker, epoch: 2)
        #expect(throws: MobileRemoteVaultManifestError.invalidSignature) {
            try fixture.verifier.verifySuccessor(next, after: fixture.trust(fixture.genesis))
        }
    }

    @Test(arguments: ["remove", "revoke", "demote", "account", "signing", "encryption"])
    func removingAuthorityRequiresKeyRotation(change: String) throws {
        let fixture = try Fixture(team: true)
        let trusted = try fixture.trust(fixture.genesis)
        var participants = [fixture.owner]
        if change != "remove" {
            participants.append(try fixture.peer(
                role: change == "demote" ? .viewer : .editor,
                revoked: change == "revoke",
                account: change == "account" ? "replacement-account" : nil,
                signingKey: change == "signing" ? Curve25519.Signing.PrivateKey() : nil,
                encryptionKey: change == "encryption" ? Curve25519.KeyAgreement.PrivateKey() : nil
            ))
        }
        let next = try fixture.successor(participants: participants)
        #expect(throws: MobileRemoteVaultManifestError.keyRotationRequired) {
            try fixture.verifier.verifySuccessor(next, after: trusted)
        }
    }

    @Test func rotatedRevocationAlsoDeniesRecordWritesAndOldKeyDelivery() async throws {
        let fixture = try Fixture(team: true)
        let next = try fixture.successor(participants: [fixture.owner], epoch: 2)
        let trusted = try fixture.verifier.verifySuccessor(next, after: fixture.trust(fixture.genesis))
        let merger = try MobileRemoteVaultMergePolicy(membership: trusted)
        let context = try MobileRemoteVaultContext(
            accountID: fixture.account, vaultID: fixture.vaultID, recordID: UUID(),
            kind: .profile, keyEpoch: 2, revision: 1
        )
        let envelope = try MobileRemoteVaultCipher().encrypt(
            Data("record".utf8), context: context, key: SymmetricKey(size: .bits256)
        )
        let revision = try MobileRemoteVaultRevision(
            accountID: fixture.account, vaultID: fixture.vaultID, recordID: context.recordID,
            kind: .profile, keyEpoch: 2, revision: 1, deleted: false,
            writerDeviceID: fixture.peerID, payloadDigest: MobileRemoteVaultRevision.digest(of: envelope)
        ).signed(by: fixture.peerKey)
        await #expect(throws: MobileRemoteVaultMergeError.writerNotAuthorized) {
            try await merger.apply(envelope: envelope, revision: revision)
        }
        let oldEnvelope = try fixture.keyEnvelope()
        #expect(throws: MobileRemoteVaultManifestError.envelopeNotAuthorized) {
            try fixture.open(oldEnvelope, using: trusted)
        }
    }

    @Test(arguments: ["stale", "skip", "fork", "epoch"])
    func rejectsStaleSkippedForkedAndSkippedEpochUpdates(change: String) throws {
        let fixture = try Fixture()
        let trusted = try fixture.trust(fixture.genesis)
        let next = try fixture.proposal(
            participants: fixture.genesis.participants,
            revision: change == "stale" ? 1 : (change == "skip" ? 3 : 2),
            previous: change == "stale" ? nil : (change == "fork" ? Data(repeating: 1, count: 32) : fixture.genesis.digest),
            epoch: change == "epoch" ? 3 : 1
        ).signed(by: fixture.ownerKey)
        #expect(throws: change == "epoch" ? MobileRemoteVaultManifestError.invalidEpochTransition : .brokenChain) {
            try fixture.verifier.verifySuccessor(next, after: trusted)
        }
    }

    @Test(arguments: ["account", "vault", "organization"])
    func rejectsScopeSubstitution(change: String) throws {
        let fixture = try Fixture(team: true)
        #expect(throws: MobileRemoteVaultManifestError.contextMismatch) {
            try fixture.verifier.verifyGenesis(
                fixture.genesis,
                accountID: change == "account" ? "another-account" : fixture.account,
                vaultID: change == "vault" ? UUID() : fixture.vaultID,
                scope: change == "organization" ? .team(organizationID: "another-org") : fixture.policy.scope,
                approvedDigest: fixture.genesis.digest
            )
        }
    }

    @Test func organizationRecoveryIsExplicitSignedAndCannotUseDeviceEnrollment() throws {
        let fixture = try Fixture(team: true)
        let recoveryID = UUID()
        let recoveryKey = Curve25519.KeyAgreement.PrivateKey()
        let policy = try MobileRemoteVaultRecoveryPolicy(scope: fixture.policy.scope, organizationRecoveryKeyID: recoveryID)
        let next = try fixture.successor(
            participants: fixture.genesis.participants, policy: policy,
            recoveryKey: recoveryKey.publicKey.rawRepresentation
        )
        let trusted = try fixture.verifier.verifySuccessor(next, after: fixture.trust(fixture.genesis))
        #expect(trusted.manifest.recoveryPolicy.organizationRecoveryKeyID == recoveryID)
        let envelope = try fixture.keyEnvelope(recipientID: recoveryID, recipientKey: recoveryKey)
        #expect(throws: MobileRemoteVaultManifestError.envelopeNotAuthorized) {
            try trusted.openDeviceKeyEnvelope(
                envelope, recipientAccountID: fixture.account, recipientDeviceID: recoveryID,
                recipientEncryptionKey: recoveryKey
            )
        }
        let removed = try fixture.proposal(
            participants: fixture.genesis.participants, revision: 3, previous: next.digest
        ).signed(by: fixture.ownerKey)
        #expect(throws: MobileRemoteVaultManifestError.keyRotationRequired) {
            try fixture.verifier.verifySuccessor(removed, after: trusted)
        }
    }

    @Test func modifiedOrganizationRecoveryKeyInvalidatesSignature() throws {
        let fixture = try Fixture(team: true)
        let policy = try MobileRemoteVaultRecoveryPolicy(scope: fixture.policy.scope, organizationRecoveryKeyID: UUID())
        let proposal = try fixture.successor(
            participants: fixture.genesis.participants, policy: policy,
            recoveryKey: Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
        )
        let tampered = try fixture.proposal(
            participants: proposal.participants, revision: 2, previous: fixture.genesis.digest,
            policy: policy, recoveryKey: Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation,
            signature: proposal.signature
        )
        #expect(throws: MobileRemoteVaultManifestError.invalidSignature) {
            try fixture.verifier.verifySuccessor(tampered, after: fixture.trust(fixture.genesis))
        }
    }

    @Test func ordinaryEnvelopeDeliveryChecksRecipientAccountAndApprovedKeys() throws {
        let fixture = try Fixture(team: true)
        let trusted = try fixture.trust(fixture.genesis)
        let envelope = try fixture.keyEnvelope()
        #expect(try fixture.open(envelope, using: trusted) == fixture.vaultKey)
        #expect(throws: MobileRemoteVaultManifestError.envelopeNotAuthorized) {
            try trusted.openDeviceKeyEnvelope(
                envelope, recipientAccountID: "wrong-account", recipientDeviceID: fixture.peerID,
                recipientEncryptionKey: fixture.peerEncryptionKey
            )
        }
        #expect(throws: MobileRemoteVaultManifestError.envelopeNotAuthorized) {
            try trusted.openDeviceKeyEnvelope(
                envelope, recipientAccountID: fixture.peerAccount, recipientDeviceID: fixture.peerID,
                recipientEncryptionKey: Curve25519.KeyAgreement.PrivateKey()
            )
        }
        let editorSigned = try fixture.keyEnvelope(senderID: fixture.peerID, senderKey: fixture.peerKey)
        #expect(throws: MobileRemoteVaultManifestError.envelopeNotAuthorized) {
            try fixture.open(editorSigned, using: trusted)
        }
    }

    @Test func invalidMembershipAndRecoveryAreRejectedBeforeTrust() throws {
        let fixture = try Fixture()
        #expect(throws: MobileRemoteVaultManifestError.duplicateParticipant) {
            try fixture.proposal(participants: [fixture.owner, fixture.owner])
        }
        #expect(throws: MobileRemoteVaultManifestError.invalidManifest) {
            try fixture.proposal(participants: Array(repeating: fixture.owner, count: 257))
        }
        #expect(throws: MobileRemoteVaultManifestError.missingOwner) {
            try fixture.proposal(participants: [fixture.peer()])
        }
        #expect(throws: MobileRemoteVaultManifestError.contextMismatch) {
            try fixture.proposal(participants: [fixture.owner, fixture.peer(account: "other-account")])
        }
        #expect(throws: MobileRemoteVaultManifestError.invalidRecoveryRecipient) {
            try fixture.proposal(participants: fixture.genesis.participants, recoveryKey: Data(repeating: 1, count: 32))
        }
        #expect(throws: MobileRemoteVaultRecoveryError.organizationRecoveryRequiresTeam) {
            try MobileRemoteVaultRecoveryPolicy(scope: .personal, organizationRecoveryKeyID: UUID())
        }
    }

    @Test(arguments: ["version", "epoch", "key", "count"])
    func decodingCannotBypassValidation(change: String) throws {
        let fixture = try Fixture()
        let encoded = try JSONEncoder().encode(fixture.genesis)
        var json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var participants = try #require(json["participants"] as? [[String: Any]])
        var member = try #require(participants[0]["member"] as? [String: Any])
        switch change {
        case "version": json["version"] = 999
        case "epoch": member["keyEpoch"] = -1
        case "key": member["signingPublicKey"] = Data([1]).base64EncodedString()
        default: participants = Array(repeating: participants[0], count: 257)
        }
        participants[0]["member"] = member
        json["participants"] = participants
        let corrupted = try JSONSerialization.data(withJSONObject: json)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(MobileRemoteVaultManifest.self, from: corrupted) }
    }

    private struct Fixture {
        let account = "owner-account"
        let vaultID = UUID()
        let ownerID = UUID()
        let peerID = UUID()
        let ownerKey = Curve25519.Signing.PrivateKey()
        let peerKey = Curve25519.Signing.PrivateKey()
        let ownerEncryptionKey = Curve25519.KeyAgreement.PrivateKey()
        let peerEncryptionKey = Curve25519.KeyAgreement.PrivateKey()
        let vaultKey = Data(repeating: 42, count: 32)
        let verifier = MobileRemoteVaultManifestVerifier()
        let peerAccount: String
        let policy: MobileRemoteVaultRecoveryPolicy
        let peerRole: MobileRemoteVaultMemberRole
        var genesis: MobileRemoteVaultManifest { try! proposal(participants: [owner, peer()]).signed(by: ownerKey) }
        var owner: MobileRemoteVaultParticipant { try! participant(id: ownerID, role: .owner, signingKey: ownerKey, encryptionKey: ownerEncryptionKey) }

        init(team: Bool = false, peerRole: MobileRemoteVaultMemberRole = .editor) throws {
            self.peerAccount = team ? "peer-account" : "owner-account"
            self.policy = try MobileRemoteVaultRecoveryPolicy(scope: team ? .team(organizationID: "team-one") : .personal)
            self.peerRole = peerRole
        }

        func trust(_ manifest: MobileRemoteVaultManifest) throws -> MobileRemoteTrustedVaultManifest {
            try verifier.verifyGenesis(manifest, accountID: account, vaultID: vaultID, scope: policy.scope, approvedDigest: genesis.digest)
        }

        func participant(
            id: UUID, role: MobileRemoteVaultMemberRole,
            account: String? = nil, signingKey: Curve25519.Signing.PrivateKey = .init(),
            encryptionKey: Curve25519.KeyAgreement.PrivateKey = .init(), revoked: Bool = false
        ) throws -> MobileRemoteVaultParticipant {
            try MobileRemoteVaultParticipant(
                accountID: account ?? self.account,
                member: MobileRemoteVaultMember(
                    deviceID: id, role: role, signingPublicKey: signingKey.publicKey.rawRepresentation,
                    keyEpoch: 1, revoked: revoked
                ), encryptionPublicKey: encryptionKey.publicKey.rawRepresentation
            )
        }

        func peer(
            role: MobileRemoteVaultMemberRole? = nil, revoked: Bool = false, account: String? = nil,
            signingKey: Curve25519.Signing.PrivateKey? = nil,
            encryptionKey: Curve25519.KeyAgreement.PrivateKey? = nil
        ) throws -> MobileRemoteVaultParticipant {
            try participant(
                id: peerID, role: role ?? peerRole, account: account ?? peerAccount,
                signingKey: signingKey ?? peerKey, encryptionKey: encryptionKey ?? peerEncryptionKey, revoked: revoked
            )
        }

        func proposal(
            participants: [MobileRemoteVaultParticipant], revision: Int64 = 1, previous: Data? = nil,
            epoch: Int64 = 1, signer: UUID? = nil, policy: MobileRemoteVaultRecoveryPolicy? = nil,
            recoveryKey: Data? = nil, signature: Data? = nil
        ) throws -> MobileRemoteVaultManifest {
            try MobileRemoteVaultManifest(
                accountID: account, vaultID: vaultID, revision: revision, keyEpoch: epoch,
                previousDigest: previous, signerDeviceID: signer ?? ownerID,
                participants: participants.map { participant in
                    try MobileRemoteVaultParticipant(
                        accountID: participant.accountID,
                        member: MobileRemoteVaultMember(
                            deviceID: participant.member.deviceID, role: participant.member.role,
                            signingPublicKey: participant.member.signingPublicKey, keyEpoch: epoch,
                            revoked: participant.member.revoked
                        ), encryptionPublicKey: participant.encryptionPublicKey
                    )
                }, recoveryPolicy: policy ?? self.policy,
                organizationRecoveryPublicKey: recoveryKey, signature: signature
            )
        }

        func successor(
            participants: [MobileRemoteVaultParticipant], signer: UUID? = nil,
            key: Curve25519.Signing.PrivateKey? = nil, epoch: Int64 = 1,
            policy: MobileRemoteVaultRecoveryPolicy? = nil, recoveryKey: Data? = nil
        ) throws -> MobileRemoteVaultManifest {
            try proposal(
                participants: participants, revision: 2, previous: genesis.digest,
                epoch: epoch, signer: signer, policy: policy, recoveryKey: recoveryKey
            ).signed(by: key ?? ownerKey)
        }

        func keyEnvelope(
            senderID: UUID? = nil, senderKey: Curve25519.Signing.PrivateKey? = nil,
            recipientID: UUID? = nil, recipientKey: Curve25519.KeyAgreement.PrivateKey? = nil
        ) throws -> MobileRemoteVaultKeyEnvelope {
            try MobileRemoteVaultKeyEnvelope.seal(
                vaultKey: vaultKey, accountID: account, vaultID: vaultID, keyEpoch: 1,
                senderDeviceID: senderID ?? ownerID, senderSigningKey: senderKey ?? ownerKey,
                recipientDeviceID: recipientID ?? peerID,
                recipientEncryptionKey: (recipientKey ?? peerEncryptionKey).publicKey
            )
        }

        func open(_ envelope: MobileRemoteVaultKeyEnvelope, using trusted: MobileRemoteTrustedVaultManifest) throws -> Data {
            try trusted.openDeviceKeyEnvelope(
                envelope, recipientAccountID: peerAccount, recipientDeviceID: peerID,
                recipientEncryptionKey: peerEncryptionKey
            )
        }
    }
}
