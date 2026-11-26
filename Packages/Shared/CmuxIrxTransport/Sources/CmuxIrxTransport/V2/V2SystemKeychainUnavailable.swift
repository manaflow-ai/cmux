#if !canImport(Security)
public import Foundation

/// The Keychain adapter where Security.framework is missing: every call fails, so a store built
/// with the default adapter reads nothing and keeps nothing. Tests inject an in-memory adapter.
public struct V2SystemKeychainAccess: V2KeychainAccess, Sendable {
    /// The failure every call throws.
    public struct Unavailable: Error, Equatable, Sendable {}

    public let supportsLegacyFileKeychain = false

    public init() {}

    public func hasMigrationMarker(
        service: String,
        account: String,
        accessGroup: String?,
        dataProtection: Bool
    ) throws -> Bool {
        throw Unavailable()
    }

    public func setMigrationMarker(
        service: String,
        account: String,
        accessGroup: String?,
        dataProtection: Bool
    ) throws {
        throw Unavailable()
    }

    public func read(
        service: String,
        account: String,
        accessGroup: String?,
        dataProtection: Bool
    ) throws -> Data? {
        throw Unavailable()
    }

    public func add(
        _ data: Data,
        service: String,
        account: String,
        accessGroup: String?,
        dataProtection: Bool
    ) throws {
        throw Unavailable()
    }

    public func delete(
        service: String,
        account: String,
        accessGroup: String?,
        dataProtection: Bool
    ) throws {
        throw Unavailable()
    }
}
#endif
