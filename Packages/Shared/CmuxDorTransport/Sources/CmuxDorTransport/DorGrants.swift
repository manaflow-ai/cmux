// Standalone pair-grant verification (no iroh dependency).
//
// Grants are broker-signed Ed25519 JWS (`typ: cmux-pair-grant+jwt`) minted at
// pairing time; the dor handshake reuses them unchanged so every existing
// pairing keeps working over the relay with zero re-pairing. Verification
// mirrors the reviewed CmxIrohGrantVerifier semantics (exact-key claim shape,
// canonical UUIDs, 30s clock skew, 7-day lifetime cap, platform direction)
// against pinned raw 32-byte Ed25519 verification keys from the persisted
// trust snapshot.

import CryptoKit
import Foundation

enum DorGrantError: Error, Sendable {
    case invalidToken
    case invalidHeader
    case invalidSignature
    case invalidClaims
    case expired
    case identityMismatch
}

struct DorGrantPeerClaims: Decodable, Equatable, Sendable {
    let bindingID: String
    let deviceID: String
    let tag: String
    let platform: String
    let endpointID: String
    let identityGeneration: Int

    private enum CodingKeys: String, CodingKey {
        case bindingID = "bindingId"
        case deviceID = "deviceId"
        case tag
        case platform
        case endpointID = "endpointId"
        case identityGeneration
    }
}

struct DorPairGrantClaims: Decodable, Equatable, Sendable {
    let grantID: String
    let issuedAt: Int64
    let notBefore: Int64
    let expiresAt: Int64
    let alpn: String
    let scope: String
    let initiator: DorGrantPeerClaims
    let acceptor: DorGrantPeerClaims

    private enum CodingKeys: String, CodingKey {
        case grantID = "jti"
        case issuedAt = "iat"
        case notBefore = "nbf"
        case expiresAt = "exp"
        case alpn
        case scope
        case initiator
        case acceptor
    }
}

enum DorGrantVerifier {
    private static let pairType = "cmux-pair-grant+jwt"
    private static let alpn = "cmux/mobile/1"
    private static let pairScope = "cmux.mobile.attach"
    private static let pairLifetime: Int64 = 7 * 24 * 60 * 60
    private static let clockSkew: Int64 = 30

    private struct Header: Decodable {
        let alg: String
        let typ: String
        let kid: String
    }

    /// Verify a pair grant and pin it to the handshake-authenticated
    /// initiator identity and the local acceptor identity.
    static func verifyPairGrant(
        _ token: String,
        keys: [Data],
        authenticatedInitiatorHex: String,
        acceptorHex: String,
        now: Date = Date()
    ) throws -> DorPairGrantClaims {
        let claims = try verifiedClaims(token, keys: keys, now: now)
        guard claims.initiator.endpointID == authenticatedInitiatorHex,
              claims.initiator.platform == "ios",
              claims.acceptor.endpointID == acceptorHex
        else {
            throw DorGrantError.identityMismatch
        }
        return claims
    }

    /// Decode WITHOUT verification, for routing only (the phone reads its own
    /// cached grant to learn the Mac's deviceID before dialing; cryptographic
    /// verification happens on the responder and in identity pinning).
    static func decodeClaimsForRouting(_ token: String) -> DorPairGrantClaims? {
        let segments = token.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count == 3,
              let payload = Data(base64URLOrStandard: String(segments[1]))
        else { return nil }
        return try? JSONDecoder().decode(DorPairGrantClaims.self, from: payload)
    }

    private static func verifiedClaims(
        _ token: String,
        keys: [Data],
        now: Date
    ) throws -> DorPairGrantClaims {
        guard (5 ... 16 * 1_024).contains(token.utf8.count) else {
            throw DorGrantError.invalidToken
        }
        let segments = token.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count == 3,
              let headerData = Data(base64URLOrStandard: String(segments[0])),
              let payload = Data(base64URLOrStandard: String(segments[1])),
              let signature = Data(base64URLOrStandard: String(segments[2])),
              signature.count == 64
        else {
            throw DorGrantError.invalidToken
        }
        let header: Header
        do {
            header = try JSONDecoder().decode(Header.self, from: headerData)
        } catch {
            throw DorGrantError.invalidHeader
        }
        guard header.alg == "EdDSA", header.typ == pairType else {
            throw DorGrantError.invalidHeader
        }
        // Pinned raw keys carry no kid: the signature must verify under one
        // of the (at most two) trust-snapshot keys.
        let signingInput = Data("\(segments[0]).\(segments[1])".utf8)
        guard keys.contains(where: { key in
            key.count == 32 && DorEd25519.verify(
                signature: signature, message: signingInput, publicKey: key)
        }) else {
            throw DorGrantError.invalidSignature
        }

        try requireExactKeys(
            payload,
            keys: ["jti", "iat", "nbf", "exp", "alpn", "scope", "initiator", "acceptor"]
        )
        let claims: DorPairGrantClaims
        do {
            claims = try JSONDecoder().decode(DorPairGrantClaims.self, from: payload)
        } catch {
            throw DorGrantError.invalidClaims
        }
        let nowSeconds = Int64(now.timeIntervalSince1970)
        let futureTolerance = nowSeconds + clockSkew
        guard isCanonicalUUID(claims.grantID),
              claims.alpn == alpn,
              claims.scope == pairScope,
              claims.notBefore <= futureTolerance,
              claims.expiresAt > claims.notBefore,
              claims.expiresAt - claims.issuedAt <= pairLifetime,
              claims.issuedAt <= futureTolerance,
              validPeer(claims.initiator),
              validPeer(claims.acceptor),
              claims.initiator.platform == "ios",
              claims.acceptor.platform == "mac"
        else {
            throw DorGrantError.invalidClaims
        }
        guard claims.expiresAt > nowSeconds else {
            throw DorGrantError.expired
        }
        return claims
    }

    private static func requireExactKeys(_ data: Data, keys: Set<String>) throws {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == keys
        else {
            throw DorGrantError.invalidClaims
        }
        let peerKeys: Set<String> = [
            "bindingId", "deviceId", "tag", "platform", "endpointId", "identityGeneration",
        ]
        guard let initiator = object["initiator"] as? [String: Any],
              let acceptor = object["acceptor"] as? [String: Any],
              Set(initiator.keys) == peerKeys,
              Set(acceptor.keys) == peerKeys
        else {
            throw DorGrantError.invalidClaims
        }
    }

    private static func validPeer(_ peer: DorGrantPeerClaims) -> Bool {
        isCanonicalUUID(peer.bindingID)
            && isCanonicalUUID(peer.deviceID)
            && !peer.tag.isEmpty && peer.tag.utf8.count <= 64
            && isCanonicalIdentityHex(peer.endpointID)
            && (1 ... Int(Int32.max)).contains(peer.identityGeneration)
    }

    private static func isCanonicalUUID(_ value: String) -> Bool {
        guard let uuid = UUID(uuidString: value) else { return false }
        return uuid.uuidString.lowercased() == value.lowercased()
            && value == value.lowercased()
    }

    static func isCanonicalIdentityHex(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { byte in
            (0x30 ... 0x39).contains(byte) || (0x61 ... 0x66).contains(byte)
        }
    }
}
