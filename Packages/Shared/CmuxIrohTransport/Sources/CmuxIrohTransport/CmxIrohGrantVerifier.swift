import CryptoKit
public import CMUXMobileCore
public import Foundation

/// Verifies broker Ed25519 credentials before they can authorize an Iroh stream.
public struct CmxIrohGrantVerifier: Sendable {
    private struct Header: Decodable {
        let alg: String
        let typ: String
        let kid: String
    }

    private static let pairType = "cmux-pair-grant+jwt"
    private static let attestationType = "cmux-endpoint-attestation-v1+jwt"
    private static let alpn = "cmux/mobile/1"
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
        keys: CmxIrohGrantVerificationKeySet,
        initiator: CmxIrohGrantPeer,
        acceptor: CmxIrohGrantPeer,
        now: Date
    ) throws -> CmxIrohPairGrantClaims {
        let claims = try verifiedPairClaims(token, keys: keys, now: now)
        guard claims.initiator == initiator, claims.acceptor == acceptor else {
            throw CmxIrohGrantVerifierError.identityMismatch
        }
        return claims
    }

    /// Verifies a grant against the TLS initiator and the Mac's exact local binding.
    public func verifyPairGrant(
        _ token: String,
        keys: CmxIrohGrantVerificationKeySet,
        authenticatedInitiatorID: CmxIrohPeerIdentity,
        acceptor: CmxIrohGrantPeer,
        now: Date
    ) throws -> CmxIrohPairGrantClaims {
        let claims = try verifiedPairClaims(token, keys: keys, now: now)
        guard claims.initiator.endpointID == authenticatedInitiatorID,
              claims.initiator.platform == .ios,
              claims.acceptor == acceptor else {
            throw CmxIrohGrantVerifierError.identityMismatch
        }
        return claims
    }

    private func verifiedPairClaims(
        _ token: String,
        keys: CmxIrohGrantVerificationKeySet,
        now: Date
    ) throws -> CmxIrohPairGrantClaims {
        let payload = try verifiedPayload(token, type: Self.pairType, keys: keys)
        try Self.requireExactKeys(
            payload,
            keys: ["jti", "iat", "nbf", "exp", "alpn", "scope", "initiator", "acceptor"]
        )
        let claims: CmxIrohPairGrantClaims
        do {
            claims = try JSONDecoder().decode(CmxIrohPairGrantClaims.self, from: payload)
        } catch {
            throw CmxIrohGrantVerifierError.invalidClaims
        }
        let nowSeconds = try Self.seconds(now)
        let futureTolerance = try Self.sum(nowSeconds, 30)
        let lifetime = try Self.difference(claims.expiresAt, claims.issuedAt)
        guard Self.isCanonicalUUID(claims.grantID),
              claims.alpn == Self.alpn,
              claims.scope == Self.pairScope,
              claims.notBefore <= futureTolerance,
              claims.expiresAt > claims.notBefore,
              lifetime <= Self.pairLifetime,
              claims.issuedAt <= futureTolerance,
              Self.validPeer(claims.initiator),
              Self.validPeer(claims.acceptor),
              claims.initiator.platform == .ios,
              claims.acceptor.platform == .mac else {
            throw CmxIrohGrantVerifierError.invalidClaims
        }
        guard claims.expiresAt > nowSeconds else {
            throw CmxIrohGrantVerifierError.expired
        }
        return claims
    }

    /// Verifies one cached endpoint attestation against an exact local binding tuple.
    public func verifyEndpointAttestation(
        _ token: String,
        keys: CmxIrohGrantVerificationKeySet,
        expected: CmxIrohEndpointExpectation,
        now: Date
    ) throws -> CmxIrohEndpointAttestationClaims {
        let claims = try verifiedEndpointClaims(token, keys: keys, now: now)
        guard claims.bindingID == expected.bindingID,
              claims.deviceID == expected.deviceID,
              claims.endpointID == expected.endpointID,
              claims.identityGeneration == expected.identityGeneration,
              claims.platform == expected.platform else {
            throw CmxIrohGrantVerifierError.identityMismatch
        }
        return claims
    }

    /// Verifies a peer attestation when the signed tuple is authoritative and TLS pins its EndpointID.
    public func verifyEndpointAttestation(
        _ token: String,
        keys: CmxIrohGrantVerificationKeySet,
        authenticatedEndpointID: CmxIrohPeerIdentity,
        requiredPlatform: CmxIrohPlatform,
        now: Date
    ) throws -> CmxIrohEndpointAttestationClaims {
        let claims = try verifiedEndpointClaims(token, keys: keys, now: now)
        guard claims.endpointID == authenticatedEndpointID,
              claims.platform == requiredPlatform else {
            throw CmxIrohGrantVerifierError.identityMismatch
        }
        return claims
    }

    private func verifiedEndpointClaims(
        _ token: String,
        keys: CmxIrohGrantVerificationKeySet,
        now: Date
    ) throws -> CmxIrohEndpointAttestationClaims {
        let payload = try verifiedPayload(token, type: Self.attestationType, keys: keys)
        try Self.requireExactKeys(
            payload,
            keys: [
                "version", "jti", "sub", "bindingId", "deviceId", "endpointId",
                "identityGeneration", "platform", "iat", "nbf", "exp", "alpn", "scope",
            ]
        )
        let claims: CmxIrohEndpointAttestationClaims
        do {
            claims = try JSONDecoder().decode(CmxIrohEndpointAttestationClaims.self, from: payload)
        } catch {
            throw CmxIrohGrantVerifierError.invalidClaims
        }
        let nowSeconds = try Self.seconds(now)
        let futureTolerance = try Self.sum(nowSeconds, 30)
        let notBeforeFloor = try Self.difference(claims.issuedAt, 30)
        let lifetime = try Self.difference(claims.expiresAt, claims.issuedAt)
        guard claims.version == 1,
              Self.isCanonicalUUID(claims.attestationID),
              Self.isCanonicalUUID(claims.bindingID),
              Self.isCanonicalUUID(claims.deviceID),
              Self.decodeBase64URL(claims.accountSubject)?.count == 32,
              (1 ... Int(Int32.max)).contains(claims.identityGeneration),
              claims.alpn == Self.alpn,
              claims.scope == Self.attestationScope,
              claims.notBefore >= notBeforeFloor,
              claims.notBefore <= futureTolerance,
              claims.expiresAt > claims.notBefore,
              lifetime <= Self.attestationLifetime,
              claims.issuedAt <= futureTolerance else {
            throw CmxIrohGrantVerifierError.invalidClaims
        }
        guard claims.expiresAt > nowSeconds else {
            throw CmxIrohGrantVerifierError.expired
        }
        return claims
    }

    /// Verifies both offline attestations and their same-account relationship.
    public func verifyOfflineSameAccountPair(
        initiatorToken: String,
        acceptorToken: String,
        keys: CmxIrohGrantVerificationKeySet,
        initiator: CmxIrohEndpointExpectation,
        acceptor: CmxIrohEndpointExpectation,
        now: Date
    ) throws -> CmxIrohVerifiedOfflinePair {
        guard initiator.platform == .ios, acceptor.platform == .mac else {
            throw CmxIrohGrantVerifierError.invalidClaims
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
              let left = Self.decodeBase64URL(initiatorClaims.accountSubject),
              let right = Self.decodeBase64URL(acceptorClaims.accountSubject),
              Self.constantTimeEqual(left, right) else {
            throw CmxIrohGrantVerifierError.accountMismatch
        }
        return CmxIrohVerifiedOfflinePair(
            initiator: initiatorClaims,
            acceptor: acceptorClaims
        )
    }

    private func verifiedPayload(
        _ token: String,
        type: String,
        keys: CmxIrohGrantVerificationKeySet
    ) throws -> Data {
        guard (5 ... 16 * 1_024).contains(token.utf8.count) else {
            throw CmxIrohGrantVerifierError.invalidToken
        }
        let segments = token.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count == 3,
              let headerData = Self.decodeBase64URL(String(segments[0])),
              let payload = Self.decodeBase64URL(String(segments[1])),
              let signature = Self.decodeBase64URL(String(segments[2])),
              signature.count == 64 else {
            throw CmxIrohGrantVerifierError.invalidToken
        }
        try Self.requireExactKeys(headerData, keys: ["alg", "typ", "kid"])
        let header: Header
        do {
            header = try JSONDecoder().decode(Header.self, from: headerData)
        } catch {
            throw CmxIrohGrantVerifierError.invalidHeader
        }
        guard header.alg == "EdDSA", header.typ == type, Self.isSafeKeyID(header.kid) else {
            throw CmxIrohGrantVerifierError.invalidHeader
        }
        let publicKey = try Self.publicKey(id: header.kid, keySet: keys)
        let signingInput = Data("\(segments[0]).\(segments[1])".utf8)
        guard publicKey.isValidSignature(signature, for: signingInput) else {
            throw CmxIrohGrantVerifierError.invalidSignature
        }
        return payload
    }

    private static func publicKey(
        id: String,
        keySet: CmxIrohGrantVerificationKeySet
    ) throws -> Curve25519.Signing.PublicKey {
        guard keySet.version == 1,
              (1 ... 2).contains(keySet.keys.count),
              isSafeKeyID(keySet.currentKeyID),
              Set(keySet.keys.map(\.kid)).count == keySet.keys.count,
              keySet.keys.contains(where: { $0.kid == keySet.currentKeyID }) else {
            throw CmxIrohGrantVerifierError.invalidKeySet
        }
        for key in keySet.keys {
            guard isSafeKeyID(key.kid), key.alg == "EdDSA",
                  let der = Data(base64Encoded: key.spkiDerBase64),
                  der.base64EncodedString() == key.spkiDerBase64,
                  der.count == ed25519SPKIPrefix.count + 32,
                  der.prefix(ed25519SPKIPrefix.count) == ed25519SPKIPrefix else {
                throw CmxIrohGrantVerifierError.invalidKeySet
            }
        }
        guard let selected = keySet.keys.first(where: { $0.kid == id }) else {
            throw CmxIrohGrantVerifierError.unknownKeyID
        }
        let der = Data(base64Encoded: selected.spkiDerBase64)!
        do {
            return try Curve25519.Signing.PublicKey(
                rawRepresentation: der.suffix(32)
            )
        } catch {
            throw CmxIrohGrantVerifierError.invalidKeySet
        }
    }

    private static func requireExactKeys(_ data: Data, keys: Set<String>) throws {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == keys else {
            throw CmxIrohGrantVerifierError.invalidClaims
        }
        if keys.contains("initiator") {
            let peerKeys: Set<String> = [
                "bindingId", "deviceId", "tag", "platform", "endpointId", "identityGeneration",
            ]
            guard let initiator = object["initiator"] as? [String: Any],
                  let acceptor = object["acceptor"] as? [String: Any],
                  Set(initiator.keys) == peerKeys,
                  Set(acceptor.keys) == peerKeys else {
                throw CmxIrohGrantVerifierError.invalidClaims
            }
        }
    }

    private static func validPeer(_ peer: CmxIrohGrantPeer) -> Bool {
        isCanonicalUUID(peer.bindingID)
            && isCanonicalUUID(peer.deviceID)
            && (1 ... 64).contains(peer.tag.utf8.count)
            && (1 ... Int(Int32.max)).contains(peer.identityGeneration)
    }

    private static func isCanonicalUUID(_ value: String) -> Bool {
        UUID(uuidString: value)?.uuidString.lowercased() == value
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

    private static func decodeBase64URL(_ value: String) -> Data? {
        guard !value.isEmpty,
              value.utf8.allSatisfy({ byte in
                  (48 ... 57).contains(byte)
                      || (65 ... 90).contains(byte)
                      || (97 ... 122).contains(byte)
                      || byte == 45 || byte == 95
              }) else {
            return nil
        }
        let padding = String(repeating: "=", count: (4 - value.count % 4) % 4)
        let standard = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/") + padding
        guard let data = Data(base64Encoded: standard), base64URL(data) == value else {
            return nil
        }
        return data
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func seconds(_ date: Date) throws -> Int64 {
        let value = date.timeIntervalSince1970
        guard value.isFinite,
              value >= TimeInterval(Int64.min),
              value <= TimeInterval(Int64.max) else {
            throw CmxIrohGrantVerifierError.invalidClaims
        }
        return Int64(value.rounded(.down))
    }

    private static func sum(_ left: Int64, _ right: Int64) throws -> Int64 {
        let result = left.addingReportingOverflow(right)
        guard !result.overflow else { throw CmxIrohGrantVerifierError.invalidClaims }
        return result.partialValue
    }

    private static func difference(_ left: Int64, _ right: Int64) throws -> Int64 {
        let result = left.subtractingReportingOverflow(right)
        guard !result.overflow else { throw CmxIrohGrantVerifierError.invalidClaims }
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
