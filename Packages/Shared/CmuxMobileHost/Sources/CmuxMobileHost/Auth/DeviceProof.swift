import CmuxMobileWire
import CryptoKit
import Foundation

/// `hello.auth`: a paired device's signature binding this hello to one host
/// and one link session (b5-mac-host.md section 3). ECDSA P-256, raw r||s,
/// base64url without padding, over `message(...)`.
public struct DeviceProof: Hashable, Sendable {
    public var install: String
    public var keyID: String
    /// Unix milliseconds when the device signed.
    public var issuedAt: Int64
    public var signature: Data

    public init(install: String, keyID: String, issuedAt: Int64, signature: Data) {
        self.install = install
        self.keyID = keyID
        self.issuedAt = issuedAt
        self.signature = signature
    }

    /// Signs with any P-256 signer (a Secure Enclave key on iOS, a software
    /// key in tests). `sign` returns the raw r||s signature of its input.
    public init(install: String, keyID: String, issuedAt: Int64, hostID: String, sessionID: UUID,
                sign: (Data) throws -> Data) rethrows {
        self.install = install
        self.keyID = keyID
        self.issuedAt = issuedAt
        signature = try sign(Self.signedBytes(hostID: hostID, sessionID: sessionID, install: install, issuedAt: issuedAt))
    }

    /// Decodes the `auth` member of a hello; nil when absent or malformed.
    public init?(json: JSONValue?) {
        guard let o = json?.objectValue,
              let install = o["install"]?.stringValue,
              let keyID = o["key_id"]?.stringValue,
              case .int(let issuedAt)? = o["issued_at"],
              let sig = o["sig"]?.stringValue,
              let signature = Data(base64URL: sig) else { return nil }
        self.init(install: install, keyID: keyID, issuedAt: issuedAt, signature: signature)
    }

    public var jsonValue: JSONValue {
        .object([
            "install": .string(install),
            "key_id": .string(keyID),
            "issued_at": .int(issuedAt),
            "sig": .string(signature.base64URLEncodedString()),
        ])
    }

    /// The bytes the device signs.
    public func message(hostID: String, sessionID: UUID) -> Data {
        Self.signedBytes(hostID: hostID, sessionID: sessionID, install: install, issuedAt: issuedAt)
    }

    /// True when `publicKey` (x9.63 or raw P-256) signed `message(...)`.
    public func verifies(publicKey: Data, hostID: String, sessionID: UUID) -> Bool {
        let key = (try? P256.Signing.PublicKey(x963Representation: publicKey))
            ?? (try? P256.Signing.PublicKey(rawRepresentation: publicKey))
        guard let key, let ecdsa = try? P256.Signing.ECDSASignature(rawRepresentation: signature) else { return false }
        return key.isValidSignature(ecdsa, for: message(hostID: hostID, sessionID: sessionID))
    }

    private static func signedBytes(hostID: String, sessionID: UUID, install: String, issuedAt: Int64) -> Data {
        Data("cmux.mobile/1 hello\n\(hostID)\n\(sessionID.uuidString.lowercased())\n\(install)\n\(issuedAt)".utf8)
    }
}
