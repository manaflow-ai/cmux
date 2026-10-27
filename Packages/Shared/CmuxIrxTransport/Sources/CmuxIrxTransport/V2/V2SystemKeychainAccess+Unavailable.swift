#if !canImport(Security)
public import Foundation

/// ``V2SystemKeychainAccess`` where the platform has no Security framework (Linux). There is no
/// device-only keychain to scope an item to, so every operation throws
/// ``V2KeychainAccessError/unavailable`` rather than falling back to an unprotected store; callers that
/// run here inject their own ``V2KeychainAccess``.
public struct V2SystemKeychainAccess: V2KeychainAccess, Sendable {
    /// There is no file keychain either.
    public let supportsLegacyFileKeychain = false

    /// Creates the unavailable adapter.
    public init() {}

    public func hasMigrationMarker(
        service: String,
        account: String,
        accessGroup: String?,
        dataProtection: Bool
    ) throws -> Bool {
        throw V2KeychainAccessError.unavailable
    }

    public func setMigrationMarker(
        service: String,
        account: String,
        accessGroup: String?,
        dataProtection: Bool
    ) throws {
        throw V2KeychainAccessError.unavailable
    }

    public func read(
        service: String,
        account: String,
        accessGroup: String?,
        dataProtection: Bool
    ) throws -> Data? {
        throw V2KeychainAccessError.unavailable
    }

    public func add(
        _ data: Data,
        service: String,
        account: String,
        accessGroup: String?,
        dataProtection: Bool
    ) throws {
        throw V2KeychainAccessError.unavailable
    }

    public func delete(
        service: String,
        account: String,
        accessGroup: String?,
        dataProtection: Bool
    ) throws {
        throw V2KeychainAccessError.unavailable
    }
}
#endif
