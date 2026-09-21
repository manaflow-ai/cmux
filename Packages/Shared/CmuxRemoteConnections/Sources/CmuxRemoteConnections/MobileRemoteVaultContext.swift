public import Foundation

/// The expected ownership and version of one encrypted vault record.
///
/// Obtain this context from the requested record and trusted revision state,
/// not from an unverified envelope. Encryption does not itself prevent a server
/// from replaying an entire old vault; membership and rollback checks live above
/// this cipher.
public struct MobileRemoteVaultContext: Equatable, Sendable {
    /// Verified account owning the personal or shared vault.
    public let accountID: String
    /// Stable cryptographic vault identity, independent of its display name.
    public let vaultID: UUID
    /// Stable record identity, independent of a hostname or credential label.
    public let recordID: UUID
    /// Payload domain; changing a record's purpose invalidates authentication.
    public let kind: MobileRemoteVaultRecordKind
    /// Key rotation generation, starting at one.
    public let keyEpoch: Int64
    /// Expected record version, starting at one.
    public let revision: Int64
    /// Whether this is a deletion rather than a live value.
    public let deleted: Bool

    /// Creates a bounded authentication context for a record.
    ///
    /// - Parameters:
    ///   - accountID: Nonempty verified owner, at most 256 UTF-8 bytes.
    ///   - vaultID: Stable vault identifier.
    ///   - recordID: Stable record identifier.
    ///   - kind: Expected payload domain.
    ///   - keyEpoch: Positive key generation.
    ///   - revision: Positive record version.
    ///   - deleted: True for an authenticated deletion.
    /// - Throws: A context validation error before any encryption.
    public init(
        accountID: String,
        vaultID: UUID,
        recordID: UUID,
        kind: MobileRemoteVaultRecordKind,
        keyEpoch: Int64,
        revision: Int64,
        deleted: Bool = false
    ) throws {
        guard !accountID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              accountID.utf8.count <= 256,
              !accountID.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              keyEpoch > 0, revision > 0 else {
            throw MobileRemoteVaultError.invalidContext
        }
        self.accountID = accountID
        self.vaultID = vaultID
        self.recordID = recordID
        self.kind = kind
        self.keyEpoch = keyEpoch
        self.revision = revision
        self.deleted = deleted
    }

    /// Length-prefixed UTF-8 fields avoid delimiter and concatenation ambiguity.
    func associatedData(version: Int) -> Data {
        let fields = [
            "cmux.remote-vault.aes256gcm",
            String(version), accountID,
            vaultID.uuidString.lowercased(), recordID.uuidString.lowercased(),
            kind.rawValue, String(keyEpoch), String(revision), deleted ? "1" : "0"
        ]
        var data = Data()
        for field in fields {
            let bytes = Data(field.utf8)
            var count = UInt32(bytes.count).bigEndian
            withUnsafeBytes(of: &count) { data.append(contentsOf: $0) }
            data.append(bytes)
        }
        return data
    }
}
