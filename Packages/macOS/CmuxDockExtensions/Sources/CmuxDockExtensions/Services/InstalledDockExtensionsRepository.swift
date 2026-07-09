import Foundation

/// Persistence for the `~/.config/cmux/extensions.json` lockfile.
///
/// An actor over one file, in the mold of `JSONConfigStore`: reads decode a
/// missing file as empty, writes are atomic (temp + rename) with parents
/// created on demand, and a present-but-corrupt file refuses to be
/// overwritten so a user's real content is never clobbered by a failed parse.
public actor InstalledDockExtensionsRepository {
    /// The lockfile location this repository reads and writes.
    public nonisolated let fileURL: URL

    /// Creates a repository over the given lockfile path (use
    /// ``DockExtensionDirectories/lockFileURL`` in production).
    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// Reads the lockfile; a missing or empty file decodes as
    /// ``DockExtensionsLockFile/empty``.
    ///
    /// - Throws: Decoding errors for a present-but-unparseable file.
    public func load() throws -> DockExtensionsLockFile {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch let error as NSError
            where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            return .empty
        }
        if data.isEmpty { return .empty }
        return try Self.decoder.decode(DockExtensionsLockFile.self, from: data)
    }

    /// Writes the lockfile atomically, creating parent directories on demand.
    public func save(_ lockFile: DockExtensionsLockFile) throws {
        let parent = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let data = try Self.encoder.encode(lockFile)
        try data.write(to: fileURL, options: [.atomic])
    }

    /// Inserts or replaces the record with `record.id`.
    ///
    /// - Returns: The lockfile after the write.
    @discardableResult
    public func upsert(_ record: DockExtensionInstallRecord) throws -> DockExtensionsLockFile {
        var lockFile = try load()
        if let index = lockFile.extensions.firstIndex(where: { $0.id == record.id }) {
            lockFile.extensions[index] = record
        } else {
            lockFile.extensions.append(record)
        }
        try save(lockFile)
        return lockFile
    }

    /// Removes the record with `id` (no-op when absent).
    ///
    /// - Returns: The lockfile after the write.
    @discardableResult
    public func remove(id: String) throws -> DockExtensionsLockFile {
        var lockFile = try load()
        lockFile.extensions.removeAll { $0.id == id }
        try save(lockFile)
        return lockFile
    }

    /// Applies `mutate` to the record with `id`.
    ///
    /// - Returns: The lockfile after the write.
    /// - Throws: ``DockExtensionError/notInstalled(id:)`` when absent.
    @discardableResult
    public func updateRecord(
        id: String,
        mutate: @Sendable (inout DockExtensionInstallRecord) -> Void
    ) throws -> DockExtensionsLockFile {
        var lockFile = try load()
        guard let index = lockFile.extensions.firstIndex(where: { $0.id == id }) else {
            throw DockExtensionError.notInstalled(id: id)
        }
        mutate(&lockFile.extensions[index])
        try save(lockFile)
        return lockFile
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
