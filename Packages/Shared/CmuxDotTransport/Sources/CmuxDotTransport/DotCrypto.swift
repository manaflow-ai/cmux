// E2E channel establishment and frame sealing.
//
// The relay (Cloudflare) forwards opaque bytes; these primitives make them
// ciphertext. Handshake: signature-authenticated ephemeral X25519 (Noise-IK
// flavored), bound to the existing pair-grant trust — the initiator (phone)
// presents its grant in hs1 and signs with the Ed25519 identity the grant
// pins; the responder (Mac) signs hs2 with the identity the grant's acceptor
// tuple pins. Keys: HKDF-SHA256 over the ECDH secret salted with the
// handshake transcript. Frames: ChaChaPoly with per-direction strictly
// incrementing nonce counters (replay within a session is rejected by
// construction; a fresh session derives fresh keys from fresh ephemerals).

import CryptoKit
import Foundation

/// Leg-payload framing: first byte says handshake JSON or sealed box.
public enum DotBoxKind: UInt8, Sendable {
    case handshake = 0x01
    case sealed = 0x02
}

enum DotCryptoError: Error, Sendable {
    case malformedHandshake
    case signatureInvalid
    case identityMismatch
    case nonceExhausted
    case replayOrReorder
    case sealFailed
    case openFailed
}

struct DotHandshake1: Codable, Sendable {
    let v: Int
    let t: String
    /// base64 X25519 ephemeral public key (32 bytes).
    let eph: String
    /// base64 Ed25519 identity public key (32 bytes).
    let id: String
    /// base64 Ed25519 signature (see `DotHandshakeTranscript.hs1Message`).
    let sig: String
    /// The pair grant JWS authorizing this initiator against this acceptor.
    let grant: String
}

struct DotHandshake2: Codable, Sendable {
    let v: Int
    let t: String
    let eph: String
    let id: String
    let sig: String
    /// Responder-minted session id, confirmed inside the sealed admit frame.
    let session: String
}

enum DotHandshakeTranscript {
    static func hs1Message(eph: Data, identity: Data, grantJWS: String) -> Data {
        var message = Data("cmux-dot-hs1".utf8)
        message.append(eph)
        message.append(identity)
        message.append(Data(SHA256.hash(data: Data(grantJWS.utf8))))
        return message
    }

    static func hs2Message(responderEph: Data, initiatorEph: Data, responderIdentity: Data) -> Data {
        var message = Data("cmux-dot-hs2".utf8)
        message.append(responderEph)
        message.append(initiatorEph)
        message.append(responderIdentity)
        return message
    }
}

/// One direction's sealing state: key + strictly incrementing counter.
struct DotSealer: Sendable {
    private let key: SymmetricKey
    private var counter: UInt64 = 0

    init(key: SymmetricKey) {
        self.key = key
    }

    mutating func seal(_ plaintext: Data) throws -> Data {
        guard counter != .max else { throw DotCryptoError.nonceExhausted }
        counter += 1
        let nonce = Self.nonce(for: counter)
        do {
            let box = try ChaChaPoly.seal(plaintext, using: key, nonce: nonce)
            var framed = Data([DotBoxKind.sealed.rawValue])
            framed.append(box.combined)
            return framed
        } catch {
            throw DotCryptoError.sealFailed
        }
    }

    static func nonce(for counter: UInt64) -> ChaChaPoly.Nonce {
        var bytes = Data(count: 4)
        withUnsafeBytes(of: counter.bigEndian) { bytes.append(contentsOf: $0) }
        // 4 zero bytes || u64be counter = 12-byte nonce.
        return try! ChaChaPoly.Nonce(data: bytes)
    }
}

/// One direction's opening state: enforces the counter monotonicity the
/// sealer guarantees, so replayed or reordered boxes are rejected.
struct DotOpener: Sendable {
    private let key: SymmetricKey
    private var lastCounter: UInt64 = 0

    init(key: SymmetricKey) {
        self.key = key
    }

    mutating func open(_ framed: Data) throws -> Data {
        guard framed.count > 1, framed.first == DotBoxKind.sealed.rawValue else {
            throw DotCryptoError.openFailed
        }
        let combined = framed.dropFirst()
        // The sender's counter is the nonce's trailing 8 bytes; ChaChaPoly
        // combined format = nonce(12) || ciphertext || tag(16).
        guard combined.count > 12 + 16 else { throw DotCryptoError.openFailed }
        let nonceData = combined.prefix(12)
        let counter = nonceData.suffix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        guard counter > lastCounter else { throw DotCryptoError.replayOrReorder }
        do {
            let box = try ChaChaPoly.SealedBox(combined: combined)
            let plaintext = try ChaChaPoly.open(box, using: key)
            lastCounter = counter
            return plaintext
        } catch {
            throw DotCryptoError.openFailed
        }
    }
}

/// Derived session keys for both directions.
struct DotSessionKeys: Sendable {
    let initiatorToResponder: SymmetricKey
    let responderToInitiator: SymmetricKey

    /// shared = X25519(ownEph, peerEph); salt = SHA256(hs1JSON || hs2JSON).
    init(
        sharedSecret: SharedSecret,
        hs1Bytes: Data,
        hs2Bytes: Data
    ) {
        var transcript = hs1Bytes
        transcript.append(hs2Bytes)
        let salt = Data(SHA256.hash(data: transcript))
        initiatorToResponder = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: salt,
            sharedInfo: Data("cmux/dot/1 i2r".utf8),
            outputByteCount: 32
        )
        responderToInitiator = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: salt,
            sharedInfo: Data("cmux/dot/1 r2i".utf8),
            outputByteCount: 32
        )
    }
}

enum DotEd25519 {
    static func verify(signature: Data, message: Data, publicKey: Data) -> Bool {
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey) else {
            return false
        }
        return key.isValidSignature(signature, for: message)
    }
}

extension Data {
    init?(base64URLOrStandard string: String) {
        var normalized = string.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while normalized.count % 4 != 0 { normalized.append("=") }
        self.init(base64Encoded: normalized)
    }
}
