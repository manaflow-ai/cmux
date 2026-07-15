public import Foundation

/// Minimal secure-storage boundary used by the Iroh identity repository.
public protocol CmxIrohSecureIdentityStoring: Sendable {
    /// Loads the record for an opaque account scope.
    func read(account: String) throws -> Data?

    /// Replaces the record for an opaque account scope.
    func write(_ data: Data, account: String) throws

    /// Removes one opaque account scope.
    func delete(account: String) throws

    /// Removes every Iroh identity owned by this app installation.
    func deleteAll() throws
}
