public import Foundation

/// Minimal secure-storage boundary used by the Iroh identity repository.
public protocol CmxIrohSecureIdentityStoring: Sendable {
    /// Loads the record for an opaque account scope.
    func read(account: String) async throws -> Data?

    /// Replaces the record for an opaque account scope.
    func write(_ data: Data, account: String) async throws

    /// Removes one opaque account scope.
    func delete(account: String) async throws

    /// Removes every Iroh identity owned by this app installation.
    func deleteAll() async throws
}
