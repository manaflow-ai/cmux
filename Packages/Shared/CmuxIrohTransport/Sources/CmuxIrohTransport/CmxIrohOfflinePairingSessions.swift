import CryptoKit
public import CMUXMobileCore
public import Foundation

/// Actor-isolated one-use Mac invitation state for offline same-account pairing.
public actor CmxIrohOfflinePairingSessions {
    private struct Session: Sendable {
        let id: String
        let acceptor: CmxIrohEndpointExpectation
        let acceptorAttestation: String
        let keys: CmxIrohGrantVerificationKeySet
        let proofHash: Data
        let createdAt: Int64
        let expiresAt: Int64
        var consumedAt: Int64?
    }

    private let verifier: CmxIrohGrantVerifier
    private let randomness: any CmxIrohRandomByteGenerating
    private let makeUUID: @Sendable () -> UUID
    private var pairingEnabled: Bool
    private var revokedBindingIDs: Set<String> = []
    private var session: Session?

    public init(
        pairingEnabled: Bool,
        verifier: CmxIrohGrantVerifier = CmxIrohGrantVerifier(),
        randomness: any CmxIrohRandomByteGenerating = CmxIrohSystemRandomByteGenerator(),
        makeUUID: @escaping @Sendable () -> UUID = { UUID() }
    ) {
        self.pairingEnabled = pairingEnabled
        self.verifier = verifier
        self.randomness = randomness
        self.makeUUID = makeUUID
    }

    /// Enables or disables new and pending offline pairing admission.
    public func setPairingEnabled(_ enabled: Bool) {
        pairingEnabled = enabled
        if !enabled { session = nil }
    }

    /// Applies a local revoke immediately, before any backend refresh can arrive.
    public func revoke(bindingID: String) {
        revokedBindingIDs.insert(bindingID)
        if session?.acceptor.bindingID == bindingID { session = nil }
    }

    /// Invalidates the current QR without changing pairing policy.
    public func invalidate() {
        session = nil
    }

    /// Creates one five-minute invitation after validating the Mac's cached attestation.
    public func createInvitation(
        acceptorAttestation: String,
        keys: CmxIrohGrantVerificationKeySet,
        acceptor: CmxIrohEndpointExpectation,
        now: Date
    ) throws -> CmxIrohOfflinePairingInvitation {
        guard pairingEnabled else {
            throw CmxIrohOfflinePairingSessionError.pairingDisabled
        }
        guard !revokedBindingIDs.contains(acceptor.bindingID) else {
            throw CmxIrohOfflinePairingSessionError.revoked
        }
        guard acceptor.platform == .mac else {
            throw CmxIrohGrantVerifierError.identityMismatch
        }
        _ = try verifier.verifyEndpointAttestation(
            acceptorAttestation,
            keys: keys,
            expected: acceptor,
            now: now
        )
        let createdAt = try Self.seconds(now)
        let expiration = createdAt.addingReportingOverflow(5 * 60)
        guard !expiration.overflow else {
            throw CmxIrohOfflinePairingSessionError.invalidInvitation
        }
        let proof = try randomness.randomBytes(count: 32)
        guard proof.count == 32 else {
            throw CmxIrohOfflinePairingSessionError.randomnessUnavailable
        }
        let sessionID = makeUUID().uuidString.lowercased()
        guard Self.isCanonicalUUID(sessionID) else {
            throw CmxIrohOfflinePairingSessionError.randomnessUnavailable
        }
        session = Session(
            id: sessionID,
            acceptor: acceptor,
            acceptorAttestation: acceptorAttestation,
            keys: keys,
            proofHash: Self.proofHash(sessionID: sessionID, acceptor: acceptor, proof: proof),
            createdAt: createdAt,
            expiresAt: expiration.partialValue,
            consumedAt: nil
        )
        return CmxIrohOfflinePairingInvitation(
            sessionID: sessionID,
            proof: proof.base64URL,
            expiresAt: expiration.partialValue,
            acceptorAttestation: acceptorAttestation
        )
    }

    /// Atomically verifies and consumes one invitation against the live QUIC peer.
    public func verifyAndConsume(
        credential: CmxIrohAdmissionCredential,
        authenticatedPeerID: CmxIrohPeerIdentity,
        now: Date
    ) throws -> CmxIrohVerifiedOfflinePair {
        guard pairingEnabled else {
            throw CmxIrohOfflinePairingSessionError.pairingDisabled
        }
        guard credential.kind == .offlinePairing,
              let initiatorAttestation = credential.endpointAttestation,
              let invitationID = credential.invitationID?.value,
              let proof = credential.offlineProof,
              proof.count == 32 else {
            throw CmxIrohOfflinePairingSessionError.invalidInvitation
        }
        guard var current = session,
              current.consumedAt == nil,
              current.id == invitationID else {
            throw CmxIrohOfflinePairingSessionError.sessionUnavailable
        }
        let nowSeconds = try Self.seconds(now)
        let futureTolerance = nowSeconds.addingReportingOverflow(30)
        let lifetime = current.expiresAt.subtractingReportingOverflow(current.createdAt)
        guard !futureTolerance.overflow,
              !lifetime.overflow,
              current.createdAt <= futureTolerance.partialValue,
              lifetime.partialValue > 0,
              lifetime.partialValue <= 5 * 60,
              current.expiresAt > nowSeconds else {
            throw CmxIrohOfflinePairingSessionError.sessionUnavailable
        }
        let actualHash = Self.proofHash(
            sessionID: current.id,
            acceptor: current.acceptor,
            proof: proof
        )
        guard Self.constantTimeEqual(current.proofHash, actualHash) else {
            throw CmxIrohOfflinePairingSessionError.invalidProof
        }
        let initiatorClaims = try verifier.verifyEndpointAttestation(
            initiatorAttestation,
            keys: current.keys,
            authenticatedEndpointID: authenticatedPeerID,
            requiredPlatform: .ios,
            now: now
        )
        let initiator = CmxIrohEndpointExpectation(
            bindingID: initiatorClaims.bindingID,
            deviceID: initiatorClaims.deviceID,
            endpointID: initiatorClaims.endpointID,
            identityGeneration: initiatorClaims.identityGeneration,
            platform: initiatorClaims.platform
        )
        guard !revokedBindingIDs.contains(initiator.bindingID),
              !revokedBindingIDs.contains(current.acceptor.bindingID) else {
            throw CmxIrohOfflinePairingSessionError.revoked
        }
        let verified = try verifier.verifyOfflineSameAccountPair(
            initiatorToken: initiatorAttestation,
            acceptorToken: current.acceptorAttestation,
            keys: current.keys,
            initiator: initiator,
            acceptor: current.acceptor,
            now: now
        )
        current.consumedAt = nowSeconds
        session = current
        return verified
    }

    private static func proofHash(
        sessionID: String,
        acceptor: CmxIrohEndpointExpectation,
        proof: Data
    ) -> Data {
        var transcript = Data(
            "cmux/iroh/offline-pair-session/v1\n\(sessionID)\n\(acceptor.bindingID)\n\(acceptor.deviceID)\n\(acceptor.endpointID.endpointID)\n\(acceptor.identityGeneration)\n\(acceptor.platform.rawValue)\n".utf8
        )
        transcript.append(proof)
        return Data(SHA256.hash(data: transcript))
    }

    private static func seconds(_ date: Date) throws -> Int64 {
        let value = date.timeIntervalSince1970
        guard value.isFinite,
              value >= TimeInterval(Int64.min),
              value <= TimeInterval(Int64.max) else {
            throw CmxIrohOfflinePairingSessionError.invalidInvitation
        }
        return Int64(value.rounded(.down))
    }

    private static func isCanonicalUUID(_ value: String) -> Bool {
        UUID(uuidString: value)?.uuidString.lowercased() == value
    }

    private static func constantTimeEqual(_ left: Data, _ right: Data) -> Bool {
        guard left.count == right.count else { return false }
        var difference: UInt8 = 0
        for (lhs, rhs) in zip(left, right) { difference |= lhs ^ rhs }
        return difference == 0
    }
}

private extension Data {
    var base64URL: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
