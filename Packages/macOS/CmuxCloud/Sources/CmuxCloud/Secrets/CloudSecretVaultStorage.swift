import Foundation

/// Where the vault document lives. The document holds values, so an implementation
/// must be encrypted at rest and must never log what it stores.
public protocol CloudSecretVaultStorage: Sendable {
    /// The stored document, or `nil` when nothing was ever saved.
    func load() throws -> Data?
    /// Replaces the stored document.
    func save(_ data: Data) throws
    /// Removes the stored document; succeeds when there is none.
    func delete() throws
}
