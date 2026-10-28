import CmuxThreading
public import Foundation

/// Where the helper keeps the value each applied fix replaced, so `revert`
/// restores the user's own setting.
///
/// Callers make one call at a time (``ServerHelperService`` runs every request
/// through its `FixQueue`), so a read-modify-write never interleaves with another.
public protocol ServerFixPriorStore: Sendable {
    func prior(_ fix: ServerFix) async -> Int?
    /// Keeps the first recorded value: applying twice never loses the original.
    func record(_ fix: ServerFix, prior: Int) async throws
    func clear(_ fix: ServerFix) async throws
}

/// A JSON file owned by root (the helper runs as root), one per helper label.
///
/// Every read and write runs on `files`, never on the caller's thread and
/// never under a lock (Chrome's ImportantFileWriter writes on its own sequence
/// the same way, base/files/important_file_writer.h). A record or clear is
/// awaited: the helper changes a setting only after the value it replaces is
/// on disk.
public final nonisolated class FileFixPriorStore: ServerFixPriorStore {
    private let file: ServerFixPriorFile
    private let files: any ServerFixPriorFiles

    /// - Parameters:
    ///   - url: The JSON file.
    ///   - files: Runs the file reads and writes (the helper's ``ServerHelperFileLane``).
    public init(url: URL, files: any ServerFixPriorFiles) {
        file = ServerFixPriorFile(url: url)
        self.files = files
    }

    /// `/Library/Application Support/cmux/server-helper/<label>.json`.
    public static func standard(label: String, files: any ServerFixPriorFiles) -> FileFixPriorStore {
        FileFixPriorStore(url: URL(filePath: "/Library/Application Support/cmux/server-helper").appending(path: "\(label).json"),
                          files: files)
    }

    public func prior(_ fix: ServerFix) async -> Int? {
        let (file, key) = (file, fix.rawValue)
        return try? await files.run { file.load()[key] }
    }

    public func record(_ fix: ServerFix, prior: Int) async throws {
        let (file, key) = (file, fix.rawValue)
        try await files.run { () throws -> Void in
            var values = file.load()
            guard values[key] == nil else { return }
            values[key] = prior
            try file.save(values)
        }
    }

    public func clear(_ fix: ServerFix) async throws {
        let (file, key) = (file, fix.rawValue)
        try await files.run { () throws -> Void in
            var values = file.load()
            guard values.removeValue(forKey: key) != nil else { return }
            try file.save(values)
        }
    }
}

/// In memory, for tests and dry runs.
public final nonisolated class MemoryFixPriorStore: ServerFixPriorStore {
    private let values = Mutex<[ServerFix: Int]>([:])

    public init() {}

    public func prior(_ fix: ServerFix) -> Int? { values.withLock { $0[fix] } }
    public func record(_ fix: ServerFix, prior: Int) { values.withLock { if $0[fix] == nil { $0[fix] = prior } } }
    public func clear(_ fix: ServerFix) { values.withLock { _ = $0.removeValue(forKey: fix) } }
}
