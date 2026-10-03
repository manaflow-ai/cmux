import CryptoKit
public import Foundation

/// The per-user secret salt behind every handle. Tests pass a fixed one.
public protocol AccountLabelSaltProviding: Sendable {
    func salt() throws -> Data
}

/// Reads the salt once (off the main actor) and keeps the labeler. When
/// the salt cannot be read or created, a random salt for this process is
/// used instead: handles then change on the next launch but never leak.
public actor AccountLabelerStore {
    private let provider: any AccountLabelSaltProviding
    private var cached: AccountLabeler?
    /// True when the Keychain salt failed and this process uses a random one.
    public private(set) var usesEphemeralSalt = false

    public init(provider: any AccountLabelSaltProviding) {
        self.provider = provider
    }

    public func labeler() -> AccountLabeler {
        if let cached { return cached }
        let salt: Data
        if let stored = try? provider.salt(), stored.count >= 16 {
            salt = stored
        } else {
            salt = AccountLabelSalt.random()
            usesEphemeralSalt = true
        }
        let labeler = AccountLabeler(salt: salt)
        cached = labeler
        return labeler
    }
}

enum AccountLabelSalt {
    /// 32 random bytes.
    static func random() -> Data {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    }
}
