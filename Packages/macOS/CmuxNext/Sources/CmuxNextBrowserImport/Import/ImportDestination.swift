import Foundation

/// Creates cmux browser profiles (data-model.md 5). The caller picks the id
/// so a retry finds the same record; returns the profile id to import into.
/// Until browser profile records exist, the App passes `DefaultProfileOnly`.
public protocol BrowserProfileProvisioning: Sendable {
    func createProfile(id: String, name: String, color: String?, source: [String: String]) async throws -> String
}

/// Keeps every import in the default browser profile; the mapping still
/// records each source's proposed profile id so it can be split later.
public struct DefaultProfileOnly: BrowserProfileProvisioning {
    public init() {}
    public func createProfile(id: String, name: String, color: String?, source: [String: String]) async throws -> String {
        "default"
    }
}

/// Receives each source profile's data after it is read. The App saves it
/// (``ImportedDataStore``) and feeds the live browser (omnibar history).
public protocol ImportDestination: Sendable {
    func commit(_ batch: ImportBatch) async throws
}
