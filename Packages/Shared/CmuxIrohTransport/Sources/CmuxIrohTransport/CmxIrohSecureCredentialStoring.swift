public import Foundation

/// Secure persistence boundary for short-lived Iroh capability records.
public protocol CmxIrohSecureCredentialStoring: Sendable {
    /// Loads the record for an opaque account scope.
    ///
    /// - Parameter account: A repository-derived scope that contains no account identifier.
    /// - Returns: The stored capability record, or `nil` when none exists.
    func read(account: String) async throws -> Data?

    /// Replaces the record for an opaque account scope.
    ///
    /// - Parameters:
    ///   - data: The capability record to store.
    ///   - account: A repository-derived scope that contains no account identifier.
    ///   - accessibility: The required Keychain data-protection policy.
    func write(
        _ data: Data,
        account: String,
        accessibility: CmxIrohSecureCredentialAccessibility
    ) async throws

    /// Removes one opaque account scope.
    ///
    /// - Parameter account: The repository-derived scope to remove.
    func delete(account: String) async throws

    /// Removes every Iroh capability owned by this app installation.
    func deleteAll() async throws
}
