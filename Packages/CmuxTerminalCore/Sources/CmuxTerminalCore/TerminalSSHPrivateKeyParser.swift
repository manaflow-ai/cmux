import CryptoKit
public import Foundation
@preconcurrency import NIOSSH

/// Parses unencrypted OpenSSH private keys (Ed25519 and ECDSA P-256/P-384/P-521).
public enum TerminalSSHPrivateKeyParser {
    /// Parses an OpenSSH private key from its PEM text.
    ///
    /// Supports unencrypted `openssh-key-v1` keys of type `ssh-ed25519` and
    /// `ecdsa-sha2-nistp{256,384,521}`. The embedded public key is validated against the
    /// derived public key.
    ///
    /// - Parameter privateKeyText: The OpenSSH PEM private key text.
    /// - Returns: The parsed key and its OpenSSH public key string.
    /// - Throws: ``TerminalSSHPrivateKeyParserError`` if the key is malformed, encrypted, or
    ///   uses an unsupported type.
    public static func parse(_ privateKeyText: String) throws -> TerminalParsedSSHPrivateKey {
        let pemBody = try extractPEMBody(from: privateKeyText)
        guard let payload = Data(base64Encoded: pemBody) else {
            throw TerminalSSHPrivateKeyParserError.invalidFormat
        }

        var reader = Reader(data: payload)
        guard reader.readMagic() == "openssh-key-v1\0" else {
            throw TerminalSSHPrivateKeyParserError.invalidFormat
        }

        let cipherName = try reader.readString()
        let kdfName = try reader.readString()
        _ = try reader.readData()
        let keyCount = try reader.readUInt32()

        guard cipherName == "none", kdfName == "none" else {
            throw TerminalSSHPrivateKeyParserError.encryptedKeysUnsupported
        }
        guard keyCount == 1 else {
            throw TerminalSSHPrivateKeyParserError.unsupportedKeyType
        }

        _ = try reader.readData()
        let privateSection = try reader.readData()
        var privateReader = Reader(data: privateSection)

        let check1 = try privateReader.readUInt32()
        let check2 = try privateReader.readUInt32()
        guard check1 == check2 else {
            throw TerminalSSHPrivateKeyParserError.invalidFormat
        }

        let keyType = try privateReader.readString()
        switch keyType {
        case "ssh-ed25519":
            return try parseEd25519PrivateKey(from: &privateReader)
        case "ecdsa-sha2-nistp256":
            return try parseECDSAPrivateKey(from: &privateReader, curve: .p256)
        case "ecdsa-sha2-nistp384":
            return try parseECDSAPrivateKey(from: &privateReader, curve: .p384)
        case "ecdsa-sha2-nistp521":
            return try parseECDSAPrivateKey(from: &privateReader, curve: .p521)
        default:
            throw TerminalSSHPrivateKeyParserError.unsupportedKeyType
        }
    }

    private static func extractPEMBody(from privateKeyText: String) throws -> String {
        let lines = privateKeyText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard lines.first == "-----BEGIN OPENSSH PRIVATE KEY-----",
              lines.last == "-----END OPENSSH PRIVATE KEY-----",
              lines.count >= 3 else {
            throw TerminalSSHPrivateKeyParserError.invalidFormat
        }

        return lines.dropFirst().dropLast().joined()
    }

    private struct Reader {
        private let data: Data
        private var offset = 0

        init(data: Data) {
            self.data = data
        }

        mutating func readMagic() -> String? {
            guard let range = data[offset...].firstRange(of: Data([0])) else { return nil }
            let nextOffset = range.upperBound
            let value = String(data: data[offset..<nextOffset], encoding: .utf8)
            offset = nextOffset
            return value
        }

        mutating func readUInt32() throws -> UInt32 {
            guard offset + 4 <= data.count else {
                throw TerminalSSHPrivateKeyParserError.invalidFormat
            }
            let slice = data[offset..<(offset + 4)]
            offset += 4
            return slice.reduce(UInt32.zero) { partialResult, byte in
                (partialResult << 8) | UInt32(byte)
            }
        }

        mutating func readData() throws -> Data {
            let length = try Int(readUInt32())
            guard offset + length <= data.count else {
                throw TerminalSSHPrivateKeyParserError.invalidFormat
            }
            let value = data[offset..<(offset + length)]
            offset += length
            return Data(value)
        }

        mutating func readString() throws -> String {
            let value = try readData()
            guard let string = String(data: value, encoding: .utf8) else {
                throw TerminalSSHPrivateKeyParserError.invalidFormat
            }
            return string
        }
    }

    private static func parseEd25519PrivateKey(from reader: inout Reader) throws -> TerminalParsedSSHPrivateKey {
        let publicKeyData = try reader.readData()
        let privateKeyData = try reader.readData()
        _ = try reader.readData()

        guard publicKeyData.count == 32, privateKeyData.count == 64 else {
            throw TerminalSSHPrivateKeyParserError.invalidKeyMaterial
        }

        let seed = privateKeyData.prefix(32)
        let embeddedPublicKey = privateKeyData.suffix(32)
        let signingKey: Curve25519.Signing.PrivateKey
        do {
            signingKey = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
        } catch {
            throw TerminalSSHPrivateKeyParserError.invalidKeyMaterial
        }

        let derivedPublicKey = signingKey.publicKey.rawRepresentation
        guard Data(derivedPublicKey) == publicKeyData, Data(derivedPublicKey) == embeddedPublicKey else {
            throw TerminalSSHPrivateKeyParserError.invalidKeyMaterial
        }

        return parsedKey(NIOSSHPrivateKey(ed25519Key: signingKey))
    }

    private static func parseECDSAPrivateKey(
        from reader: inout Reader,
        curve: ECDSACurve
    ) throws -> TerminalParsedSSHPrivateKey {
        let domainParameter = try reader.readString()
        guard domainParameter == curve.domainParameter else {
            throw TerminalSSHPrivateKeyParserError.invalidKeyMaterial
        }

        let publicKeyData = try reader.readData()
        let privateScalarData = try reader.readData()
        _ = try reader.readData()

        let normalizedPrivateScalar = try normalizedMPInt(privateScalarData, targetLength: curve.privateScalarLength)

        switch curve {
        case .p256:
            return try parsedECDSAKey(
                rawRepresentation: normalizedPrivateScalar,
                publicKeyData: publicKeyData,
                makePrivateKey: { try P256.Signing.PrivateKey(rawRepresentation: $0) },
                makeSSHPublicKey: { NIOSSHPrivateKey(p256Key: $0) },
                publicKeyDataForKey: { Data($0.publicKey.x963Representation) }
            )
        case .p384:
            return try parsedECDSAKey(
                rawRepresentation: normalizedPrivateScalar,
                publicKeyData: publicKeyData,
                makePrivateKey: { try P384.Signing.PrivateKey(rawRepresentation: $0) },
                makeSSHPublicKey: { NIOSSHPrivateKey(p384Key: $0) },
                publicKeyDataForKey: { Data($0.publicKey.x963Representation) }
            )
        case .p521:
            return try parsedECDSAKey(
                rawRepresentation: normalizedPrivateScalar,
                publicKeyData: publicKeyData,
                makePrivateKey: { try P521.Signing.PrivateKey(rawRepresentation: $0) },
                makeSSHPublicKey: { NIOSSHPrivateKey(p521Key: $0) },
                publicKeyDataForKey: { Data($0.publicKey.x963Representation) }
            )
        }
    }

    private static func parsedECDSAKey<SigningKey>(
        rawRepresentation: Data,
        publicKeyData: Data,
        makePrivateKey: (Data) throws -> SigningKey,
        makeSSHPublicKey: (SigningKey) -> NIOSSHPrivateKey,
        publicKeyDataForKey: (SigningKey) -> Data
    ) throws -> TerminalParsedSSHPrivateKey {
        let signingKey: SigningKey
        do {
            signingKey = try makePrivateKey(rawRepresentation)
        } catch {
            throw TerminalSSHPrivateKeyParserError.invalidKeyMaterial
        }

        guard publicKeyDataForKey(signingKey) == publicKeyData else {
            throw TerminalSSHPrivateKeyParserError.invalidKeyMaterial
        }

        return parsedKey(makeSSHPublicKey(signingKey))
    }

    private static func normalizedMPInt(_ value: Data, targetLength: Int) throws -> Data {
        var normalizedValue = value
        if normalizedValue.count == targetLength + 1, normalizedValue.first == 0 {
            normalizedValue.removeFirst()
        }
        guard normalizedValue.count <= targetLength else {
            throw TerminalSSHPrivateKeyParserError.invalidKeyMaterial
        }
        if normalizedValue.count < targetLength {
            normalizedValue = Data(repeating: 0, count: targetLength - normalizedValue.count) + normalizedValue
        }
        return normalizedValue
    }

    private static func parsedKey(_ privateKey: NIOSSHPrivateKey) -> TerminalParsedSSHPrivateKey {
        TerminalParsedSSHPrivateKey(
            privateKey: privateKey,
            openSSHPublicKey: String(openSSHPublicKey: privateKey.publicKey)
        )
    }

    private enum ECDSACurve {
        case p256
        case p384
        case p521

        var domainParameter: String {
            switch self {
            case .p256:
                return "nistp256"
            case .p384:
                return "nistp384"
            case .p521:
                return "nistp521"
            }
        }

        var privateScalarLength: Int {
            switch self {
            case .p256:
                return 32
            case .p384:
                return 48
            case .p521:
                return 66
            }
        }
    }
}
