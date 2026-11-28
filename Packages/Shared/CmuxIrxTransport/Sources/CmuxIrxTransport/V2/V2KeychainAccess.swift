public import Foundation

/// The operations required by v2's device-only keychain persistence.
///
/// Keeping this seam typed makes migration behavior testable without reading a
/// real user's keychain. Implementations must scope every operation to the
/// supplied service, account, access group, and keychain domain.
public protocol V2KeychainAccess: Sendable {
    /// Whether this backend has a distinct legacy file-keychain domain.
    ///
    /// The production system adapter derives this from the platform. Keeping
    /// the capability on the backend prevents callers from accidentally
    /// enabling a file-keychain probe on iOS, where the Security framework can
    /// treat both domains as the same store.
    var supportsLegacyFileKeychain: Bool { get }

    /// Reads the fixed migration-complete marker from one primary item.
    ///
    /// A missing item or marker returns `false`; other Security failures throw
    /// so callers do not silently fall back to a legacy identity.
    /// - Parameters:
    ///   - service: The exact generic-password service.
    ///   - account: The exact generic-password account.
    ///   - accessGroup: The optional signing-entitled keychain group.
    ///   - dataProtection: Whether to use the Data Protection Keychain.
    /// - Returns: Whether this exact item carries the migration marker.
    /// - Throws: ``V2KeychainAccessError`` when Security cannot inspect it.
    func hasMigrationMarker(
        service: String,
        account: String,
        accessGroup: String?,
        dataProtection: Bool
    ) throws -> Bool

    /// Writes the fixed migration-complete marker to one existing item.
    ///
    /// Implementations must update marker metadata only. Service, account,
    /// value, and other identity-scoping attributes remain immutable.
    /// - Parameters:
    ///   - service: The exact generic-password service.
    ///   - account: The exact generic-password account.
    ///   - accessGroup: The optional signing-entitled keychain group.
    ///   - dataProtection: Whether to use the Data Protection Keychain.
    /// - Throws: ``V2KeychainAccessError`` when Security cannot persist it.
    func setMigrationMarker(
        service: String,
        account: String,
        accessGroup: String?,
        dataProtection: Bool
    ) throws

    /// Reads one generic-password value, returning `nil` only when absent.
    /// - Parameters:
    ///   - service: The exact generic-password service.
    ///   - account: The exact generic-password account.
    ///   - accessGroup: The optional signing-entitled keychain group.
    ///   - dataProtection: Whether to use the Data Protection Keychain.
    /// - Returns: The stored bytes, or `nil` when no item exists.
    /// - Throws: ``V2KeychainAccessError`` when Security cannot read the item.
    func read(
        service: String,
        account: String,
        accessGroup: String?,
        dataProtection: Bool
    ) throws -> Data?

    /// Adds one generic-password value.
    /// - Parameters:
    ///   - data: The bytes to persist.
    ///   - service: The exact generic-password service.
    ///   - account: The exact generic-password account.
    ///   - accessGroup: The optional signing-entitled keychain group.
    ///   - dataProtection: Whether to use the Data Protection Keychain.
    /// - Throws: ``V2KeychainAccessError/duplicate`` when another writer won.
    func add(
        _ data: Data,
        service: String,
        account: String,
        accessGroup: String?,
        dataProtection: Bool
    ) throws

    /// Deletes one exact generic-password value.
    /// - Parameters:
    ///   - service: The exact generic-password service.
    ///   - account: The exact generic-password account.
    ///   - accessGroup: The optional signing-entitled keychain group.
    ///   - dataProtection: Whether to use the Data Protection Keychain.
    /// - Throws: ``V2KeychainAccessError`` when Security cannot delete the item.
    func delete(
        service: String,
        account: String,
        accessGroup: String?,
        dataProtection: Bool
    ) throws
}
