import Foundation

/// The JSON stored by ``CloudSecretVaultStorage``:
/// `{version, hmacKey (base64), secrets: [{record, value}], ledger: [...]}`.
///
/// Internal: only ``CloudSecretVault`` reads or writes it.
///
/// Forward compatibility: an older build that decodes a newer document drops the
/// fields it does not know, and its next write would erase them. So any change to the
/// stored shape (a new field here, in ``Entry``, ``CloudSecretRecord`` or
/// ``CloudSecretDelivery``) bumps ``currentVersion``; ``decode(_:)`` then makes the
/// older build refuse the vault instead of rewriting it.
struct CloudSecretVaultDocument: Codable, Equatable {
    static let currentVersion = 1

    /// One stored secret: its metadata and its value.
    struct Entry: Codable, Equatable {
        var record: CloudSecretRecord
        var value: String
    }

    var version: Int
    /// Base64 of the 32-byte fingerprint key; empty until the first secret is saved.
    var hmacKey: String
    var secrets: [Entry]
    var ledger: [CloudSecretDelivery]

    init(version: Int = currentVersion, hmacKey: String = "", secrets: [Entry] = [], ledger: [CloudSecretDelivery] = []) {
        self.version = version
        self.hmacKey = hmacKey
        self.secrets = secrets
        self.ledger = ledger
    }

    private enum CodingKeys: String, CodingKey {
        case version, hmacKey, secrets, ledger
    }

    private struct VersionProbe: Decodable {
        let version: Int
    }

    /// Decodes stored bytes, refusing a newer format before reading anything else so a
    /// downgrade never misreads (and later overwrites) a newer vault.
    static func decode(_ data: Data) throws -> CloudSecretVaultDocument {
        let decoder = JSONDecoder()
        guard let probe = try? decoder.decode(VersionProbe.self, from: data) else {
            throw CloudSecretVaultError.corrupt
        }
        guard probe.version <= currentVersion else {
            throw CloudSecretVaultError.unsupportedVersion(probe.version)
        }
        guard let document = try? decoder.decode(CloudSecretVaultDocument.self, from: data) else {
            throw CloudSecretVaultError.corrupt
        }
        return document
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }
}
