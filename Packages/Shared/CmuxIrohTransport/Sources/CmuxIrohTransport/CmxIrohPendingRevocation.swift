import Foundation

/// A non-secret broker binding queued for revocation on its owning account.
public struct CmxIrohPendingRevocation: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case accountID
        case tag
        case bindingID
    }

    /// The exact authenticated account allowed to revoke the binding.
    public let accountID: String

    /// The build tag that created the binding.
    public let tag: String

    /// The broker-owned lowercase binding UUID.
    public let bindingID: String

    /// Creates a validated device-local revocation record.
    ///
    /// - Parameters:
    ///   - accountID: The exact authenticated account that owns the binding.
    ///   - tag: The safe build tag that created the binding.
    ///   - bindingID: The broker-owned lowercase binding UUID.
    /// - Throws: ``CmxIrohPendingRevocationError/invalidRecord`` for malformed input.
    public init(accountID: String, tag: String, bindingID: String) throws {
        guard Self.isSafeAccountID(accountID),
              Self.isSafeTag(tag),
              Self.isCanonicalUUID(bindingID) else {
            throw CmxIrohPendingRevocationError.invalidRecord
        }
        self.accountID = accountID
        self.tag = tag
        self.bindingID = bindingID
    }

    /// Decodes and revalidates one device-local revocation record.
    ///
    /// - Parameter decoder: The decoder containing the stored record.
    /// - Throws: ``CmxIrohPendingRevocationError/invalidRecord`` for malformed input.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            accountID: container.decode(String.self, forKey: .accountID),
            tag: container.decode(String.self, forKey: .tag),
            bindingID: container.decode(String.self, forKey: .bindingID)
        )
    }

    static func isSafeAccountID(_ value: String) -> Bool {
        (1 ... 1_024).contains(value.utf8.count)
            && !value.unicodeScalars.contains(where: {
                $0.value <= 0x1f || $0.value == 0x7f
            })
    }

    static func isSafeTag(_ value: String) -> Bool {
        guard (1 ... 64).contains(value.utf8.count) else { return false }
        return value.utf8.allSatisfy { byte in
            (48 ... 57).contains(byte)
                || (65 ... 90).contains(byte)
                || (97 ... 122).contains(byte)
                || [45, 46, 58, 95].contains(byte)
        }
    }

    private static func isCanonicalUUID(_ value: String) -> Bool {
        UUID(uuidString: value)?.uuidString.lowercased() == value
    }
}
