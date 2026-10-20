import Darwin
import Foundation

/// One app-local history file retained across the daemon handoff.
struct LegacyHistoryFile: Equatable, Sendable {
    let url: URL
    private let identity: Identity

    init?(url: URL, supportDirectory: URL) {
        let support = supportDirectory.standardizedFileURL
        let candidate = url.standardizedFileURL
        let supportParts = support.pathComponents
        let candidateParts = candidate.pathComponents
        guard candidateParts.count > supportParts.count,
              Array(candidateParts.prefix(supportParts.count)) == supportParts,
              Self.isDirectoryWithoutSymlink(support) else { return nil }

        var current = support
        var identity: Identity?
        for component in candidateParts.dropFirst(supportParts.count) {
            current.append(path: component)
            guard let found = Self.identity(at: current), !found.isSymbolicLink else { return nil }
            identity = found
        }
        guard let identity, identity.isRegularFile else { return nil }
        self.url = candidate
        self.identity = identity
    }

    func removeIfUnchanged() {
        guard Self.identity(at: url) == identity else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private struct Identity: Equatable, Sendable {
        let device: UInt64
        let inode: UInt64
        let size: Int64
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64
        let kind: mode_t

        var isSymbolicLink: Bool { kind == S_IFLNK }
        var isRegularFile: Bool { kind == S_IFREG }
    }

    private static func identity(at url: URL) -> Identity? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        return Identity(
            device: UInt64(info.st_dev),
            inode: UInt64(info.st_ino),
            size: info.st_size,
            modifiedSeconds: info.st_mtimespec.tv_sec,
            modifiedNanoseconds: info.st_mtimespec.tv_nsec,
            kind: info.st_mode & S_IFMT
        )
    }

    private static func isDirectoryWithoutSymlink(_ url: URL) -> Bool {
        identity(at: url)?.kind == S_IFDIR
    }
}
