public import Foundation

/// Where the helper keeps the value each applied fix replaced, so `revert`
/// restores the user's own setting.
public protocol ServerFixPriorStore: Sendable {
    func prior(_ fix: ServerFix) -> Int?
    /// Keeps the first recorded value: applying twice never loses the original.
    func record(_ fix: ServerFix, prior: Int) throws
    func clear(_ fix: ServerFix) throws
}

/// A JSON file owned by root (the helper runs as root), one per helper label.
public final nonisolated class FileFixPriorStore: ServerFixPriorStore, @unchecked Sendable {
    private let url: URL
    private let lock = NSLock() // concurrency-allow: guards one small file read-modify-write, never held across an await

    public init(url: URL) {
        self.url = url
    }

    /// `/Library/Application Support/cmux/server-helper/<label>.json`.
    public static func standard(label: String) -> FileFixPriorStore {
        FileFixPriorStore(url: URL(filePath: "/Library/Application Support/cmux/server-helper").appending(path: "\(label).json"))
    }

    public func prior(_ fix: ServerFix) -> Int? {
        lock.withLock { load()[fix.rawValue] }
    }

    public func record(_ fix: ServerFix, prior: Int) throws {
        try lock.withLock {
            var values = load()
            guard values[fix.rawValue] == nil else { return }
            values[fix.rawValue] = prior
            try save(values)
        }
    }

    public func clear(_ fix: ServerFix) throws {
        try lock.withLock {
            var values = load()
            guard values.removeValue(forKey: fix.rawValue) != nil else { return }
            try save(values)
        }
    }

    /// The store directory must be owned by the helper's user (root) and
    /// closed to everyone else; anything else is refused, never trusted.
    private func directoryIsTrusted() -> Bool {
        let directory = url.deletingLastPathComponent().path
        var info = stat()
        guard lstat(directory, &info) == 0 else { return true } // created by save()
        return (info.st_mode & S_IFMT) == S_IFDIR && info.st_uid == geteuid() && (info.st_mode & 0o077) == 0
    }

    private func load() -> [String: Int] {
        guard directoryIsTrusted(), let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: Int].self, from: data)) ?? [:]
    }

    private func save(_ values: [String: Int]) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard directoryIsTrusted() else { throw CocoaError(.fileWriteNoPermission) }
        try JSONEncoder().encode(values).write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

/// In memory, for tests and dry runs.
public final nonisolated class MemoryFixPriorStore: ServerFixPriorStore, @unchecked Sendable {
    private let lock = NSLock() // concurrency-allow: guards one dictionary access, never held across an await or IO
    private var values: [ServerFix: Int] = [:]

    public init() {}

    public func prior(_ fix: ServerFix) -> Int? { lock.withLock { values[fix] } }
    public func record(_ fix: ServerFix, prior: Int) throws { lock.withLock { if values[fix] == nil { values[fix] = prior } } }
    public func clear(_ fix: ServerFix) throws { lock.withLock { _ = values.removeValue(forKey: fix) } }
}
