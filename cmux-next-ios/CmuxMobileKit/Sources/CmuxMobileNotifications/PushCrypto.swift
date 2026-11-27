import CryptoKit
import Foundation

/// The crypto of sealed pushes and mailbox replies (PROTOCOL.md "Sealed pushes
/// and the reply mailbox"), shared by the app and its notification service
/// extension. cmux-mobile-host `seal.rs` does the same on the Mac.
///
/// Seal (ECIES, P-256): an ephemeral key `E`; `z = ECDH(E, R)`;
/// `k = HKDF-SHA256(ikm: z, salt: E_pub || R_pub, info: context, 32)`;
/// AES-256-GCM with a random 12-byte nonce and `context` as associated data.
/// Wire: base64url (no padding) of `0x01 || E_pub (65) || nonce (12) || ciphertext || tag (16)`.
public struct PushSeal: Sendable {
    public static let version: UInt8 = 1

    public enum Failure: Error, Equatable, Sendable {
        /// Not base64url, the wrong version, or too short.
        case malformed
        /// A public key that is not a P-256 point.
        case badKey
        /// The tag did not verify: another key, another context, or changed bytes.
        case openFailed
    }

    public init() {}

    /// The domain, then each field after one NUL byte (as every cmux-mobile signature).
    public static func joined(_ domain: String, _ parts: [String]) -> Data {
        var data = Data(domain.utf8)
        for part in parts {
            data.append(0)
            data.append(Data(part.utf8))
        }
        return data
    }

    /// The context a push for `phone` is sealed under.
    public static func pushContext(mac: String, phone: String, eventId: String) -> Data {
        joined("cmux-mobile-push-seal-v1", [mac, phone, eventId])
    }

    /// The context a mailbox reply to `mac` is sealed under.
    public static func replyContext(mac: String, phone: String, replyId: String) -> Data {
        joined("cmux-mobile-reply-seal-v1", [mac, phone, replyId])
    }

    /// Seals `plaintext` to `recipient` (X9.63). `ephemeral` and `nonce` are
    /// parameters for the fixed test vectors only.
    public static func seal(_ plaintext: Data, to recipient: Data, context: Data,
                            ephemeral: P256.KeyAgreement.PrivateKey = P256.KeyAgreement.PrivateKey(),
                            nonce: AES.GCM.Nonce = AES.GCM.Nonce()) throws -> String {
        guard let recipientKey = try? P256.KeyAgreement.PublicKey(x963Representation: recipient) else { throw Failure.badKey }
        let shared = try ephemeral.sharedSecretFromKeyAgreement(with: recipientKey)
        let ephemeralPublic = ephemeral.publicKey.x963Representation
        let key = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: ephemeralPublic + recipient,
                                                 sharedInfo: context, outputByteCount: 32)
        let box = try AES.GCM.seal(plaintext, using: key, nonce: nonce, authenticating: context)
        var wire = Data([version])
        wire.append(ephemeralPublic)
        wire.append(contentsOf: nonce)
        wire.append(box.ciphertext)
        wire.append(box.tag)
        return base64url(wire)
    }

    /// Opens a sealed box. `recipient` is the opening key's public half
    /// (X9.63); `agree` runs ECDH with the private half (a Secure Enclave key
    /// on a phone, a software key on the simulator and in tests).
    public static func open(_ sealed: String, recipient: Data, context: Data,
                            agree: (P256.KeyAgreement.PublicKey) throws -> SharedSecret) throws -> Data {
        guard let wire = data(base64url: sealed), wire.count >= 1 + 65 + 12 + 16, wire.first == version else { throw Failure.malformed }
        let bytes = [UInt8](wire)
        let ephemeralPublic = Data(bytes[1..<66])
        guard let ephemeral = try? P256.KeyAgreement.PublicKey(x963Representation: ephemeralPublic) else { throw Failure.badKey }
        let shared: SharedSecret
        do { shared = try agree(ephemeral) } catch { throw Failure.openFailed }
        let key = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: ephemeralPublic + recipient,
                                                 sharedInfo: context, outputByteCount: 32)
        do {
            let nonce = try AES.GCM.Nonce(data: Data(bytes[66..<78]))
            let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: Data(bytes[78..<(bytes.count - 16)]),
                                            tag: Data(bytes[(bytes.count - 16)...]))
            return try AES.GCM.open(box, using: key, authenticating: context)
        } catch {
            throw Failure.openFailed
        }
    }

    /// Opens with a software key (tests, the simulator).
    public static func open(_ sealed: String, with key: P256.KeyAgreement.PrivateKey, context: Data) throws -> Data {
        try open(sealed, recipient: key.publicKey.x963Representation, context: context) { try key.sharedSecretFromKeyAgreement(with: $0) }
    }

    public static func base64url(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// base64url with or without padding; nil for anything else.
    public static func data(base64url text: String) -> Data? {
        guard !text.contains("+"), !text.contains("/") else { return nil }
        var s = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        return Data(base64Encoded: s)
    }
}

/// ECDSA P-256 / SHA-256 signatures as raw `r || s`, keys as X9.63, both lowercase hex.
public struct PushSignature: Sendable {
    public init() {}

    public static func verify(key: String, signature: String, message: Data) -> Bool {
        guard let keyBytes = hexData(key), let signatureBytes = hexData(signature),
              let publicKey = try? P256.Signing.PublicKey(x963Representation: keyBytes),
              let ecdsa = try? P256.Signing.ECDSASignature(rawRepresentation: signatureBytes) else { return false }
        return publicKey.isValidSignature(ecdsa, for: message)
    }

    public static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

    /// Lowercase or uppercase hex; nil for anything else.
    public static func hexData(_ hex: String) -> Data? {
        guard hex.count.isMultiple(of: 2) else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(hex.count / 2)
        var high: UInt8?
        for unit in hex.utf8 {
            let nibble: UInt8
            switch unit {
            case 48...57: nibble = unit - 48
            case 97...102: nibble = unit - 87
            case 65...70: nibble = unit - 55
            default: return nil
            }
            if let h = high {
                bytes.append(h << 4 | nibble)
                high = nil
            } else {
                high = nibble
            }
        }
        return Data(bytes)
    }

    public static func sha256Hex(_ data: Data) -> String { hex(Data(SHA256.hash(data: data))) }
}

/// JSON with one canonical text (acpmux `canonical_json`): object keys in
/// UTF-8 byte order, no whitespace, only `"`, `\` and control characters
/// escaped. Numbers are integers only (every number a reply carries is one).
public indirect enum PushJSON: Equatable, Sendable, Codable {
    case null
    case bool(Bool)
    case int(Int64)
    case string(String)
    case array([PushJSON])
    case object([String: PushJSON])

    public var canonical: String {
        var out = ""
        write(into: &out)
        return out
    }

    private func write(into out: inout String) {
        switch self {
        case .null: out += "null"
        case .bool(let b): out += b ? "true" : "false"
        case .int(let n): out += String(n)
        case .string(let s): Self.string(s, into: &out)
        case .array(let items):
            out += "["
            for (index, item) in items.enumerated() {
                if index > 0 { out += "," }
                item.write(into: &out)
            }
            out += "]"
        case .object(let object):
            out += "{"
            for (index, key) in object.keys.sorted(by: { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }).enumerated() {
                if index > 0 { out += "," }
                Self.string(key, into: &out)
                out += ":"
                (object[key] ?? .null).write(into: &out)
            }
            out += "}"
        }
    }

    private static func string(_ s: String, into out: inout String) {
        out += "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\u{8}": out += "\\b"
            case "\u{c}": out += "\\f"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case _ where scalar.value < 0x20: out += String(format: "\\u%04x", scalar.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        out += "\""
    }

    public subscript(key: String) -> PushJSON? {
        if case .object(let object) = self { return object[key] }
        return nil
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null } else if let b = try? c.decode(Bool.self) { self = .bool(b) } else if let n = try? c.decode(Int64.self) {
            self = .int(n)
        } else if let s = try? c.decode(String.self) { self = .string(s) } else if let a = try? c.decode([PushJSON].self) {
            self = .array(a)
        } else { self = .object(try c.decode([String: PushJSON].self)) }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .int(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}
