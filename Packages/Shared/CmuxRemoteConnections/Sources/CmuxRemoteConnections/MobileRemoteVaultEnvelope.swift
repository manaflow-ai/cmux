public import Foundation

/// Versioned ciphertext for storage and transport, never a plaintext vault.
///
/// Account, vault, record, and revision binding is supplied separately through
/// ``MobileRemoteVaultContext`` when opening the record.
public struct MobileRemoteVaultEnvelope: Codable, Equatable, Sendable {
    /// AES-256-GCM with a 12-byte nonce and 16-byte tag.
    public static let currentVersion = 1
    /// One MiB per record; files and terminal history use separate storage.
    public static let maximumPayloadBytes = 1_048_576

    /// Wire format version.
    public let version: Int
    /// Nonce, ciphertext, and authentication tag in CryptoKit combined format.
    public let sealedBox: Data

    /// Validates a received envelope before a caller attempts decryption.
    ///
    /// - Parameters:
    ///   - version: Supported wire format version.
    ///   - sealedBox: Combined authenticated ciphertext.
    /// - Throws: Unsupported-version, malformed-envelope, or size errors.
    public init(version: Int = Self.currentVersion, sealedBox: Data) throws {
        guard version == Self.currentVersion else {
            throw MobileRemoteVaultError.unsupportedVersion(version)
        }
        guard sealedBox.count >= 28 else {
            throw MobileRemoteVaultError.malformedEnvelope
        }
        guard sealedBox.count <= Self.maximumPayloadBytes + 28 else {
            throw MobileRemoteVaultError.payloadTooLarge
        }
        self.version = version
        self.sealedBox = sealedBox
    }

    private enum CodingKeys: String, CodingKey { case version, sealedBox }

    /// Decodes using the same validation as direct construction.
    ///
    /// - Parameter decoder: Decoder of a bounded transport record.
    /// - Throws: Decoding or envelope-validation errors.
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            version: values.decode(Int.self, forKey: .version),
            sealedBox: values.decode(Data.self, forKey: .sealedBox)
        )
    }
}
