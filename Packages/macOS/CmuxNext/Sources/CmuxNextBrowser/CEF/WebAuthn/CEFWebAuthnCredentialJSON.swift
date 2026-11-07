import Foundation

/// A finished ceremony as `PublicKeyCredential.toJSON()` (RegistrationResponseJSON or
/// AuthenticationResponseJSON), the form `cmux_webauthn_complete` takes. Chromium parses it with
/// `MakeCredentialResponseFromValue` / `GetAssertionResponseFromValue`, which want, for create,
/// `authenticatorData`, `publicKeyAlgorithm` and (for ES256 and Ed25519) the DER `publicKey`, each
/// equal to what the attestation object holds; the fork then checks clientDataJSON and the RP ID
/// hash against the request. The person's credential bytes go only to the page that asked.
nonisolated enum CEFWebAuthnCredentialJSON {
    enum Failure: Error, Equatable { case unreadableAttestation }

    /// A new credential.
    static func registration(credentialID: Data, clientDataJSON: Data, attestationObject: Data, attachment: String,
                             transports: [String], extensions: [String: Any]) throws(Failure) -> String {
        guard let attested = AttestedKey(attestationObject: attestationObject) else { throw .unreadableAttestation }
        var response: [String: Any] = [
            "clientDataJSON": clientDataJSON.base64URL,
            "attestationObject": attestationObject.base64URL,
            "authenticatorData": attested.authenticatorData.base64URL,
            "publicKeyAlgorithm": attested.algorithm,
            "transports": transports,
        ]
        if let der = attested.publicKeyDER { response["publicKey"] = der.base64URL }
        return encode(credentialID: credentialID, attachment: attachment, response: response, extensions: extensions)
    }

    /// A sign-in with an existing credential.
    static func assertion(credentialID: Data, clientDataJSON: Data, authenticatorData: Data, signature: Data,
                          userHandle: Data?, attachment: String, extensions: [String: Any]) -> String {
        var response: [String: Any] = [
            "clientDataJSON": clientDataJSON.base64URL,
            "authenticatorData": authenticatorData.base64URL,
            "signature": signature.base64URL,
        ]
        if let userHandle, !userHandle.isEmpty { response["userHandle"] = userHandle.base64URL }
        return encode(credentialID: credentialID, attachment: attachment, response: response, extensions: extensions)
    }

    private static func encode(credentialID: Data, attachment: String, response: [String: Any],
                               extensions: [String: Any]) -> String {
        let object: [String: Any] = [
            "id": credentialID.base64URL, "rawId": credentialID.base64URL, "type": "public-key",
            "authenticatorAttachment": attachment, "response": response, "clientExtensionResults": extensions,
        ]
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}

/// The authenticator data and credential public key inside a WebAuthn attestation object (CBOR,
/// RFC 8949): `{"fmt", "attStmt", "authData"}`, authData = RP ID hash (32), flags (1), sign count
/// (4), then with the AT flag the AAGUID (16), the credential id length (2) and id, and the COSE key.
nonisolated struct AttestedKey: Equatable {
    let authenticatorData: Data
    /// The COSE algorithm (-7 ES256, -8 EdDSA, -257 RS256, ...).
    let algorithm: Int
    /// SubjectPublicKeyInfo DER for P-256 and Ed25519 keys; nil for other key types (Chromium needs
    /// it only for those two).
    let publicKeyDER: Data?

    init?(attestationObject: Data) {
        var reader = CBORReader(Array(attestationObject))
        guard let map = reader.mapCount() else { return nil }
        var authData: [UInt8]?
        for _ in 0..<map {
            guard let key = reader.text() else { return nil }
            if key == "authData" { authData = reader.bytes() } else if !reader.skip() { return nil }
            if key == "authData", authData == nil { return nil }
        }
        guard let authData, authData.count >= 37, authData[32] & 0x40 != 0, authData.count >= 55 else { return nil }
        let idLength = Int(authData[53]) << 8 | Int(authData[54])
        guard authData.count > 55 + idLength else { return nil }
        var key = CBORReader(Array(authData[(55 + idLength)...]))
        guard let entries = key.mapCount() else { return nil }
        var ints: [Int: Int] = [:]
        var bytes: [Int: [UInt8]] = [:]
        for _ in 0..<entries {
            guard let label = key.int() else { return nil }
            if let value = key.peekIsBytes ? key.bytes().map(Either.bytes) : key.int().map(Either.int) {
                switch value {
                case .bytes(let data): bytes[label] = data
                case .int(let number): ints[label] = number
                }
            } else if !key.skip() { return nil }
        }
        guard let algorithm = ints[3] else { return nil }
        authenticatorData = Data(authData)
        self.algorithm = algorithm
        // EC2 (kty 2) on P-256 (crv 1): x -2, y -3. OKP (kty 1) on Ed25519 (crv 6): x -2.
        if ints[1] == 2, ints[-1] == 1, let x = bytes[-2], let y = bytes[-3], x.count == 32, y.count == 32 {
            publicKeyDER = Self.p256Prefix + Data([0x04] + x + y)
        } else if ints[1] == 1, ints[-1] == 6, let x = bytes[-2], x.count == 32 {
            publicKeyDER = Self.ed25519Prefix + Data(x)
        } else {
            publicKeyDER = nil
        }
    }

    private enum Either { case bytes([UInt8]), int(Int) }

    private static let p256Prefix = Data([
        0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01,
        0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07, 0x03, 0x42, 0x00,
    ])
    private static let ed25519Prefix = Data([0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x03, 0x21, 0x00])
}

/// Just enough CBOR to walk an attestation object: definite-length items only, as CTAP2 requires.
nonisolated struct CBORReader {
    private let data: [UInt8]
    private var index = 0

    init(_ bytes: [UInt8]) { data = bytes }

    var peekIsBytes: Bool { index < data.count && data[index] >> 5 == 2 }

    /// The major type and argument of the next item.
    private mutating func head() -> (major: UInt8, value: UInt64)? {
        guard index < data.count else { return nil }
        let first = data[index]
        index += 1
        let info = first & 0x1f
        let width: Int
        switch info {
        case 0..<24: return (first >> 5, UInt64(info))
        case 24: width = 1
        case 25: width = 2
        case 26: width = 4
        case 27: width = 8
        default: return nil
        }
        guard index + width <= data.count else { return nil }
        var value: UInt64 = 0
        for byte in data[index..<(index + width)] { value = value << 8 | UInt64(byte) }
        index += width
        return (first >> 5, value)
    }

    mutating func mapCount() -> Int? {
        guard let (major, value) = head(), major == 5, value < 1024 else { return nil }
        return Int(value)
    }

    mutating func int() -> Int? {
        let start = index
        guard let (major, value) = head(), major <= 1, value < UInt64(Int.max) else { index = start; return nil }
        return major == 0 ? Int(value) : -1 - Int(value)
    }

    mutating func bytes() -> [UInt8]? { string(major: 2) }

    mutating func text() -> String? { string(major: 3).map { String(decoding: $0, as: UTF8.self) } }

    private mutating func string(major wanted: UInt8) -> [UInt8]? {
        let start = index
        guard let (major, value) = head(), major == wanted, value <= UInt64(data.count - index) else { index = start; return nil }
        defer { index += Int(value) }
        return Array(data[index..<(index + Int(value))])
    }

    /// Skips one item (nested maps and arrays included); false when it is malformed.
    mutating func skip(depth: Int = 0) -> Bool {
        guard depth < 16, let (major, value) = head() else { return false }
        switch major {
        case 0, 1, 7: return true
        case 2, 3:
            guard value <= UInt64(data.count - index) else { return false }
            index += Int(value)
            return true
        case 4, 5:
            guard value < 4096 else { return false }
            for _ in 0..<(Int(value) * (major == 5 ? 2 : 1)) {
                guard skip(depth: depth + 1) else { return false }
            }
            return true
        case 6: return skip(depth: depth + 1)
        default: return false
        }
    }
}
