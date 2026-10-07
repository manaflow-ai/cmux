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
    public var usesEphemeralSalt: Bool { saltFailure != nil }
    /// Why the salt failed (for example `Keychain error -25308`); never a secret.
    public private(set) var saltFailure: String?

    public init(provider: any AccountLabelSaltProviding) {
        self.provider = provider
    }

    public func labeler() -> AccountLabeler {
        if let cached { return cached }
        let salt: Data
        do {
            let stored = try provider.salt()
            guard stored.count >= 16 else { throw AccountLabelSaltTooShort() }
            salt = stored
        } catch {
            salt = AccountLabelSalt.random()
            saltFailure = String(describing: error)
        }
        let labeler = AccountLabeler(salt: salt)
        cached = labeler
        return labeler
    }
}
