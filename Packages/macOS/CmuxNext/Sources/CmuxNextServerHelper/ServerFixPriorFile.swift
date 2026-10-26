import Foundation

/// The store's file itself: plain blocking reads and writes, run only on a files lane.
nonisolated struct ServerFixPriorFile: Sendable {
    let url: URL

    /// The store directory must be owned by the helper's user (root) and
    /// closed to everyone else; anything else is refused, never trusted.
    func directoryIsTrusted() -> Bool {
        let directory = url.deletingLastPathComponent().path
        var info = stat()
        guard lstat(directory, &info) == 0 else { return true } // created by save()
        return (info.st_mode & S_IFMT) == S_IFDIR && info.st_uid == geteuid() && (info.st_mode & 0o077) == 0
    }

    func load() -> [String: Int] {
        guard directoryIsTrusted(), let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: Int].self, from: data)) ?? [:]
    }

    func save(_ values: [String: Int]) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard directoryIsTrusted() else { throw CocoaError(.fileWriteNoPermission) }
        try JSONEncoder().encode(values).write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
