// E2E channel establishment and frame sealing.
//
// The relay (Cloudflare) forwards opaque bytes; these primitives make them
// ciphertext. Handshake: signature-authenticated ephemeral X25519, bound to
// the existing pair-grant trust — the initiator (phone) presents its grant in
// hs1 and signs with the Ed25519 identity the grant pins as
// `initiator.endpointID`; the responder (Mac) signs hs2 with the identity the
// grant's acceptor tuple pins. Session keys: HKDF-SHA256 over the ECDH secret
// salted with the full handshake transcript, one key per direction. Frames:
// ChaChaPoly with strictly incrementing per-direction counters, so replay or
// reorder within a session is rejected by construction and a fresh session
// derives fresh keys from fresh ephemerals.

import CryptoKit
import Foundation

/// First byte of every leg payload: handshake JSON or sealed box.
public enum DorBoxKind: UInt8, Sendable {
    case handshake = 0x01
    case sealed = 0x02
}

enum DorCryptoError: Error, Sendable {
    case malformedHandshake
    case signatureInvalid
    case identityMismatch
    case nonceExhausted
    case replayOrReorder
    case sealFailed
    case openFailed
}

/// hs1 (phone → Mac), sent as [DorBoxKind.handshake][JSON].
struct DorHandshake1: Codable, Sendable {
    let v: Int
    let t: String // "hs1"
    /// base64 X25519 ephemeral public key (32 bytes).
    let eph: String
    /// base64 Ed25519 identity public key (32 bytes).
    let id: String
    /// base64 Ed25519 signature over `DorTranscript.hs1Message`.
    let sig: String
    /// The pair grant JWS authorizing this initiator against this acceptor.
    let grant: String
}

/// hs2 (Mac → phone).
struct DorHandshake2: Codable, Sendable {
    let v: Int
    let t: String // "hs2"
    let eph: String
    let id: String
    /// base64 Ed25519 signature over `DorTranscript.hs2Message`.
    let sig: String
    /// Responder-minted session id, confirmed inside the sealed admit frame.
    let session: String
}

/// Refusal (Mac → phone), plaintext because no session keys exist yet; the
/// phone treats it as advisory (journal + fail the current attempt).
struct DorHandshakeDeny: Codable, Sendable {
    let v: Int
    let t: String // "deny"
    let reason: String
}

enum DorTranscript {
    static func hs1Message(eph: Data, identity: Data, grantJWS: String) -> Data {
        var message = Data("cmux-dor-hs1".utf8)
        message.append(eph)
        message.append(identity)
        message.append(Data(SHA256.hash(data: Data(grantJWS.utf8))))
        return message
    }

    static func hs2Message(responderEph: Data, initiatorEph: Data, responderIdentity: Data, session: String) -> Data {
        var message = Data("cmux-dor-hs2".utf8)
        message.append(responderEph)
        message.append(initiatorEph)
        message.append(responderIdentity)
        message.append(Data(SHA256.hash(data: Data(session.utf8))))
        return message
    }
}

/// Derived session keys for both directions.
/// shared = X25519(ownEph, peerEph); salt = SHA256(hs1JSON || hs2JSON).
struct DorSessionKeys: Sendable {
    let initiatorToResponder: SymmetricKey
    let responderToInitiator: SymmetricKey

    init(sharedSecret: SharedSecret, hs1Bytes: Data, hs2Bytes: Data) {
        var transcript = hs1Bytes
        transcript.append(hs2Bytes)
        let salt = Data(SHA256.hash(data: transcript))
        initiatorToResponder = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: salt,
            sharedInfo: Data("cmux/dor/1 i2r".utf8),
            outputByteCount: 32
        )
        responderToInitiator = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: salt,
            sharedInfo: Data("cmux/dor/1 r2i".utf8),
            outputByteCount: 32
        )
    }
}

/// One direction's sealing state: key + strictly incrementing counter.
struct DorSealer: Sendable {
    private let key: SymmetricKey
    private var counter: UInt64 = 0

    init(key: SymmetricKey) {
        self.key = key
    }

    mutating func seal(_ plaintext: Data) throws -> Data {
        guard counter != .max else { throw DorCryptoError.nonceExhausted }
        counter += 1
        do {
            let box = try ChaChaPoly.seal(plaintext, using: key, nonce: Self.nonce(for: counter))
            var framed = Data([DorBoxKind.sealed.rawValue])
            framed.append(box.combined)
            return framed
        } catch {
            throw DorCryptoError.sealFailed
        }
    }

    /// 12-byte nonce: 4 zero bytes || u64be counter.
    static func nonce(for counter: UInt64) -> ChaChaPoly.Nonce {
        var bytes = Data(count: 4)
        withUnsafeBytes(of: counter.bigEndian) { bytes.append(contentsOf: $0) }
        return try! ChaChaPoly.Nonce(data: bytes)
    }
}

/// One direction's opening state: enforces the counter monotonicity the
/// sealer guarantees, so replayed or reordered boxes are rejected.
struct DorOpener: Sendable {
    private let key: SymmetricKey
    private var lastCounter: UInt64 = 0

    init(key: SymmetricKey) {
        self.key = key
    }

    mutating func open(_ framed: Data) throws -> Data {
        guard framed.count > 1, framed.first == DorBoxKind.sealed.rawValue else {
            throw DorCryptoError.openFailed
        }
        let combined = framed.dropFirst()
        // ChaChaPoly combined = nonce(12) || ciphertext || tag(16); the
        // sender's counter is the nonce's trailing 8 bytes.
        guard combined.count > 12 + 16 else { throw DorCryptoError.openFailed }
        let counter = combined.prefix(12).suffix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        guard counter > lastCounter else { throw DorCryptoError.replayOrReorder }
        do {
            let box = try ChaChaPoly.SealedBox(combined: combined)
            let plaintext = try ChaChaPoly.open(box, using: key)
            lastCounter = counter
            return plaintext
        } catch {
            throw DorCryptoError.openFailed
        }
    }
}

enum DorEd25519 {
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

    var lowercaseHex: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
