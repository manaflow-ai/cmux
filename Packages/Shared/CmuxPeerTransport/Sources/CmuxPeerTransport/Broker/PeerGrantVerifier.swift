public import CMUXMobileCore
public import Foundation
import CryptoKit

/// Verifies broker Ed25519 credentials before they can authorize a stream.
///
/// The token wire format and every claim rule are unchanged: grants and
/// attestations are minted by the same server as before, including the signed
/// `alpn` claim value `cmux/mobile/1` (a server-side constant independent of
/// the QUIC ALPN this transport dials with).
public struct PeerGrantVerifier: Sendable {
    private struct Header: Decodable {
        let alg: String
        let typ: String
        let kid: String
    }

    private static let pairType = "cmux-pair-grant+jwt"
    private static let attestationType = "cmux-endpoint-attestation-v1+jwt"
    private static let grantALPN = "cmux/mobile/1"
    private static let pairScope = "cmux.mobile.attach"
    private static let attestationScope = "cmux.offline-pair.same-account"
    private static let pairLifetime: Int64 = 7 * 24 * 60 * 60
    private static let attestationLifetime: Int64 = 24 * 60 * 60
    private static let ed25519SPKIPrefix = Data([
        0x30, 0x2a, 0x30, 0x05, 0x06, 0x03,
        0x2b, 0x65, 0x70, 0x03, 0x21, 0x00,
    ])

    public init() {}

    /// Verifies signature, claim shape, time window, platform direction, and both peers.
    public func verifyPairGrant(
        _ token: String,
        keys: PeerGrantVerificationKeySet,
        initiator: PeerGrantPeer,
        acceptor: PeerGrantPeer,
        now: Date
    ) throws -> PeerPairGrantClaims {
        let claims = try verifiedPairClaims(token, keys: keys, now: now)
        guard claims.initiator == initiator, claims.acceptor == acceptor else {
            throw PeerGrantVerifierError.identityMismatch
        }
        return claims
    }

    /// Verifies a grant against the TLS initiator and the Mac's exact local binding.
    public func verifyPairGrant(
        _ token: String,
        keys: PeerGrantVerificationKeySet,
        authenticatedInitiatorID: CmxIrohPeerIdentity,
        acceptor: PeerGrantPeer,
        now: Date
    ) throws -> PeerPairGrantClaims {
        let claims = try verifiedPairClaims(token, keys: keys, now: now)
        guard claims.initiator.endpointID == authenticatedInitiatorID,
              claims.initiator.platform == .ios,
              claims.acceptor == acceptor else {
            throw PeerGrantVerifierError.identityMismatch
        }
        return claims
    }

    private func verifiedPairClaims(
        _ token: String,
        keys: PeerGrantVerificationKeySet,
        now: Date
    ) throws -> PeerPairGrantClaims {
        let payload = try verifiedPayload(token, type: Self.pairType, keys: keys)
        try Self.requireExactKeys(
            payload,
            keys: ["jti", "iat", "nbf", "exp", "alpn", "scope", "initiator", "acceptor"]
        )
        let claims: PeerPairGrantClaims
        do {
            claims = try JSONDecoder().decode(PeerPairGrantClaims.self, from: payload)
        } catch {
            throw PeerGrantVerifierError.invalidClaims
        }
        let nowSeconds = try Self.seconds(now)
        let futureTolerance = try Self.sum(nowSeconds, 30)
        let lifetime = try Self.difference(claims.expiresAt, claims.issuedAt)
        guard PeerBrokerWire.isCanonicalUUID(claims.grantID),
              claims.alpn == Self.grantALPN,
              claims.scope == Self.pairScope,
              claims.notBefore <= futureTolerance,
              claims.expiresAt > claims.notBefore,
              lifetime <= Self.pairLifetime,
              claims.issuedAt <= futureTolerance,
              Self.validPeer(claims.initiator),
              Self.validPeer(claims.acceptor),
              claims.initiator.platform == .ios,
              claims.acceptor.platform == .mac else {
            throw PeerGrantVerifierError.invalidClaims
        }
        guard claims.expiresAt > nowSeconds else {
            throw PeerGrantVerifierError.expired
        }
        return claims
    }

    /// Verifies one cached endpoint attestation against an exact local binding tuple.
    public func verifyEndpointAttestation(
        _ token: String,
        keys: PeerGrantVerificationKeySet,
        expected: PeerEndpointExpectation,
        now: Date
    ) throws -> PeerEndpointAttestationClaims {
        let claims = try verifiedEndpointClaims(token, keys: keys, now: now)
        guard claims.bindingID == expected.bindingID,
              claims.deviceID == expected.deviceID,
              claims.endpointID == expected.endpointID,
              claims.identityGeneration == expected.identityGeneration,
              claims.platform == expected.platform else {
            throw PeerGrantVerifierError.identityMismatch
        }
        return claims
    }

    /// Verifies a peer attestation when TLS pins its EndpointID.
    public func verifyEndpointAttestation(
        _ token: String,
        keys: PeerGrantVerificationKeySet,
        authenticatedEndpointID: CmxIrohPeerIdentity,
        requiredPlatform: PeerPlatform,
        now: Date
    ) throws -> PeerEndpointAttestationClaims {
        let claims = try verifiedEndpointClaims(token, keys: keys, now: now)
        guard claims.endpointID == authenticatedEndpointID,
              claims.platform == requiredPlatform else {
            throw PeerGrantVerifierError.identityMismatch
        }
        return claims
    }

    private func verifiedEndpointClaims(
        _ token: String,
        keys: PeerGrantVerificationKeySet,
        now: Date
    ) throws -> PeerEndpointAttestationClaims {
        let payload = try verifiedPayload(token, type: Self.attestationType, keys: keys)
        try Self.requireExactKeys(
            payload,
            keys: [
                "version", "jti", "sub", "bindingId", "deviceId", "endpointId",
                "identityGeneration", "platform", "iat", "nbf", "exp", "alpn", "scope",
            ]
        )
        let claims: PeerEndpointAttestationClaims
        do {
            claims = try JSONDecoder().decode(
                PeerEndpointAttestationClaims.self,
                from: payload
            )
        } catch {
            throw PeerGrantVerifierError.invalidClaims
        }
        let nowSeconds = try Self.seconds(now)
        let futureTolerance = try Self.sum(nowSeconds, 30)
        let notBeforeFloor = try Self.difference(claims.issuedAt, 30)
        let lifetime = try Self.difference(claims.expiresAt, claims.issuedAt)
        guard claims.version == 1,
              PeerBrokerWire.isCanonicalUUID(claims.attestationID),
              PeerBrokerWire.isCanonicalUUID(claims.bindingID),
              PeerBrokerWire.isCanonicalUUID(claims.deviceID),
              PeerBrokerWire.decodeBase64URL(claims.accountSubject)?.count == 32,
              (1 ... Int(Int32.max)).contains(claims.identityGeneration),
              claims.alpn == Self.grantALPN,
              claims.scope == Self.attestationScope,
              claims.notBefore >= notBeforeFloor,
              claims.notBefore <= futureTolerance,
              claims.expiresAt > claims.notBefore,
              lifetime <= Self.attestationLifetime,
              claims.issuedAt <= futureTolerance else {
            throw PeerGrantVerifierError.invalidClaims
        }
        guard claims.expiresAt > nowSeconds else {
            throw PeerGrantVerifierError.expired
        }
        return claims
    }

    /// Verifies both offline attestations and their same-account relationship.
    public func verifyOfflineSameAccountPair(
        initiatorToken: String,
        acceptorToken: String,
        keys: PeerGrantVerificationKeySet,
        initiator: PeerEndpointExpectation,
        acceptor: PeerEndpointExpectation,
        now: Date
    ) throws -> PeerVerifiedOfflinePair {
        guard initiator.platform == .ios, acceptor.platform == .mac else {
            throw PeerGrantVerifierError.invalidClaims
        }
        let initiatorClaims = try verifyEndpointAttestation(
            initiatorToken,
            keys: keys,
            expected: initiator,
            now: now
        )
        let acceptorClaims = try verifyEndpointAttestation(
            acceptorToken,
            keys: keys,
            expected: acceptor,
            now: now
        )
        guard initiatorClaims.bindingID != acceptorClaims.bindingID,
              initiatorClaims.deviceID != acceptorClaims.deviceID,
              initiatorClaims.endpointID != acceptorClaims.endpointID,
              let left = PeerBrokerWire.decodeBase64URL(initiatorClaims.accountSubject),
              let right = PeerBrokerWire.decodeBase64URL(acceptorClaims.accountSubject),
              Self.constantTimeEqual(left, right) else {
            throw PeerGrantVerifierError.accountMismatch
        }
        return PeerVerifiedOfflinePair(
            initiator: initiatorClaims,
            acceptor: acceptorClaims
        )
    }

    private func verifiedPayload(
        _ token: String,
        type: String,
        keys: PeerGrantVerificationKeySet
    ) throws -> Data {
        guard (5 ... 16 * 1_024).contains(token.utf8.count) else {
            throw PeerGrantVerifierError.invalidToken
        }
        let segments = token.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count == 3,
              let headerData = PeerBrokerWire.decodeBase64URL(String(segments[0])),
              let payload = PeerBrokerWire.decodeBase64URL(String(segments[1])),
              let signature = PeerBrokerWire.decodeBase64URL(String(segments[2])),
              signature.count == 64 else {
            throw PeerGrantVerifierError.invalidToken
        }
        try Self.requireExactKeys(headerData, keys: ["alg", "typ", "kid"])
        let header: Header
        do {
            header = try JSONDecoder().decode(Header.self, from: headerData)
        } catch {
            throw PeerGrantVerifierError.invalidHeader
        }
        guard header.alg == "EdDSA", header.typ == type, Self.isSafeKeyID(header.kid) else {
            throw PeerGrantVerifierError.invalidHeader
        }
        let publicKey = try Self.publicKey(id: header.kid, keySet: keys)
        let signingInput = Data("\(segments[0]).\(segments[1])".utf8)
        guard publicKey.isValidSignature(signature, for: signingInput) else {
            throw PeerGrantVerifierError.invalidSignature
        }
        return payload
    }

    private static func publicKey(
        id: String,
        keySet: PeerGrantVerificationKeySet
    ) throws -> Curve25519.Signing.PublicKey {
        guard keySet.version == 1,
              (1 ... 2).contains(keySet.keys.count),
              isSafeKeyID(keySet.currentKeyID),
              Set(keySet.keys.map(\.kid)).count == keySet.keys.count,
              keySet.keys.contains(where: { $0.kid == keySet.currentKeyID }) else {
            throw PeerGrantVerifierError.invalidKeySet
        }
        for key in keySet.keys {
            guard isSafeKeyID(key.kid), key.alg == "EdDSA",
                  let der = Data(base64Encoded: key.spkiDerBase64),
                  der.base64EncodedString() == key.spkiDerBase64,
                  der.count == ed25519SPKIPrefix.count + 32,
                  der.prefix(ed25519SPKIPrefix.count) == ed25519SPKIPrefix else {
                throw PeerGrantVerifierError.invalidKeySet
            }
        }
        guard let selected = keySet.keys.first(where: { $0.kid == id }) else {
            throw PeerGrantVerifierError.unknownKeyID
        }
        let der = Data(base64Encoded: selected.spkiDerBase64)!
        do {
            return try Curve25519.Signing.PublicKey(
                rawRepresentation: der.suffix(32)
            )
        } catch {
            throw PeerGrantVerifierError.invalidKeySet
        }
    }

    private static func requireExactKeys(_ data: Data, keys: Set<String>) throws {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == keys else {
            throw PeerGrantVerifierError.invalidClaims
        }
        if keys.contains("initiator") {
            let peerKeys: Set<String> = [
                "bindingId", "deviceId", "tag", "platform", "endpointId", "identityGeneration",
            ]
            guard let initiator = object["initiator"] as? [String: Any],
                  let acceptor = object["acceptor"] as? [String: Any],
                  Set(initiator.keys) == peerKeys,
                  Set(acceptor.keys) == peerKeys else {
                throw PeerGrantVerifierError.invalidClaims
            }
        }
    }

    private static func validPeer(_ peer: PeerGrantPeer) -> Bool {
        PeerBrokerWire.isCanonicalUUID(peer.bindingID)
            && PeerBrokerWire.isCanonicalUUID(peer.deviceID)
            && (1 ... 64).contains(peer.tag.utf8.count)
            && (1 ... Int(Int32.max)).contains(peer.identityGeneration)
    }

    private static func isSafeKeyID(_ value: String) -> Bool {
        guard (1 ... 64).contains(value.utf8.count) else { return false }
        return value.utf8.allSatisfy { byte in
            (48 ... 57).contains(byte)
                || (65 ... 90).contains(byte)
                || (97 ... 122).contains(byte)
                || [45, 46, 95].contains(byte)
        }
    }

    private static func seconds(_ date: Date) throws -> Int64 {
        let value = date.timeIntervalSince1970
        guard value.isFinite,
              value >= TimeInterval(Int64.min),
              value <= TimeInterval(Int64.max) else {
            throw PeerGrantVerifierError.invalidClaims
        }
        return Int64(value.rounded(.down))
    }

    private static func sum(_ left: Int64, _ right: Int64) throws -> Int64 {
        let result = left.addingReportingOverflow(right)
        guard !result.overflow else { throw PeerGrantVerifierError.invalidClaims }
        return result.partialValue
    }

    private static func difference(_ left: Int64, _ right: Int64) throws -> Int64 {
        let result = left.subtractingReportingOverflow(right)
        guard !result.overflow else { throw PeerGrantVerifierError.invalidClaims }
        return result.partialValue
    }

    private static func constantTimeEqual(_ left: Data, _ right: Data) -> Bool {
        guard left.count == right.count else { return false }
        var difference: UInt8 = 0
        for (lhs, rhs) in zip(left, right) {
            difference |= lhs ^ rhs
        }
        return difference == 0
    }
}
