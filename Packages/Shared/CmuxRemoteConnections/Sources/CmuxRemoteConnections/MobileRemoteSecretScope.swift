import CryptoKit
public import Foundation

/// Stable local scope for one account, vault, and opaque secret item.
///
/// Hostnames and labels are deliberately absent. The Keychain account
/// attribute is a one-way digest of this scope, so Keychain metadata cannot
/// disclose a destination address or display name.
public struct MobileRemoteSecretScope: Equatable, Hashable, Sendable {
    /// Authenticated cmux account owner, bounded and free of control characters.
    public let accountID: String
    /// Cryptographic vault identity, independent of its display name.
    public let vaultID: UUID
    /// Opaque credential identity, independent of a host or label.
    public let itemID: UUID

    /// Creates a validated account/vault/item scope.
    ///
    /// - Parameters:
    ///   - accountID: Verified account identifier, at most 256 UTF-8 bytes.
    ///   - vaultID: Stable vault UUID.
    ///   - itemID: Stable credential UUID.
    /// - Throws: ``MobileRemoteSecretStoreError/invalidScope`` for malformed account IDs.
    public init(accountID: String, vaultID: UUID, itemID: UUID) throws {
        guard !accountID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              accountID.utf8.count <= 256,
              !accountID.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else {
            throw MobileRemoteSecretStoreError.invalidScope
        }
        self.accountID = accountID
        self.vaultID = vaultID
        self.itemID = itemID
    }

    /// Opaque Keychain account attribute for this scope.
    var keychainAccount: String {
        var input = Data("cmux.remote.secret.scope.v1".utf8)
        Self.appendLengthPrefixed(Data(accountID.utf8), to: &input)
        Self.appendLengthPrefixed(Data(vaultID.uuidString.lowercased().utf8), to: &input)
        Self.appendLengthPrefixed(Data(itemID.uuidString.lowercased().utf8), to: &input)
        let digest = SHA256.hash(data: input)
        return "v1." + digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func appendLengthPrefixed(_ value: Data, to data: inout Data) {
        var count = UInt32(value.count).bigEndian
        withUnsafeBytes(of: &count) { data.append(contentsOf: $0) }
        data.append(value)
    }
}
