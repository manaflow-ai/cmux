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
