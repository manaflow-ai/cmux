import Foundation

extension WorkstreamPersistence {
    /// Loads the maximum of journal bytes and the durable revision floor.
    /// Reads are bounded independently of history and metadata file size.
    public func loadRevision() throws -> Int {
        let fileRevision = (try? fileSize()) ?? 0
        return Int(min(max(fileRevision, revisionFile.read()), Self.maximumRevision))
    }

    /// Persists a high-water mark, serialized with other app and CLI writers.
    /// - Parameter revision: The generation published by the store.
    /// - Throws: A filesystem error if the revision could not be recorded.
    public func recordRevision(_ revision: Int) async throws {
        try await revisionFile.record(revision)
    }
}
