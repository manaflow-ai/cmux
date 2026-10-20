import Darwin
import Foundation

/// One app-local history file retained across the daemon handoff.
///
/// SAFETY: the directory descriptor and captured identities are immutable;
/// the descriptor closes only after the last reference is released.
final class LegacyHistoryFile: @unchecked Sendable, Equatable {
    let url: URL
    private let parentURL: URL
    private let parentDescriptor: Int32
    private let parentIdentity: Identity
    private let name: String
    private let identity: Identity

    init?(url: URL, supportDirectory: URL) {
        let support = supportDirectory.standardizedFileURL
        let candidate = url.standardizedFileURL
        let supportParts = support.pathComponents
        let candidateParts = candidate.pathComponents
        guard candidateParts.count > supportParts.count,
              Array(candidateParts.prefix(supportParts.count)) == supportParts,
              let supportIdentity = Self.directoryIdentity(at: support) else { return nil }

        var parent = support
        var expectedParent = supportIdentity
        for component in candidateParts.dropFirst(supportParts.count).dropLast() {
            parent.append(path: component)
            guard let found = Self.identity(at: parent), found.isDirectory else { return nil }
            expectedParent = found
        }
        guard let name = candidateParts.last, !name.isEmpty else { return nil }

        let descriptor = Darwin.open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        guard Self.identity(of: descriptor) == expectedParent,
              let identity = Self.identity(at: descriptor, name: name), identity.isRegularFile else {
            Darwin.close(descriptor)
            return nil
        }

        self.url = candidate
        parentURL = parent
        parentDescriptor = descriptor
        parentIdentity = expectedParent
        self.name = name
        self.identity = identity
    }

    deinit {
        Darwin.close(parentDescriptor)
    }

    static func == (lhs: LegacyHistoryFile, rhs: LegacyHistoryFile) -> Bool {
        lhs.url == rhs.url && lhs.parentIdentity == rhs.parentIdentity && lhs.identity == rhs.identity
    }

    /// Atomically moves the captured directory entry aside, verifies the
    /// moved object, and only then unlinks it. A replacement is restored or
    /// retained under the quarantine name, never deleted.
    func removeIfUnchanged() {
        guard Self.directoryIdentity(at: parentURL) == parentIdentity,
              Self.identity(at: parentDescriptor, name: name) == identity else { return }
        let quarantine = ".cmux-history-cleanup-\(UUID().uuidString.lowercased())"
        guard renameat(parentDescriptor, name, parentDescriptor, quarantine) == 0 else { return }
        guard Self.identity(at: parentDescriptor, name: quarantine) == identity else {
            if Self.identity(at: parentDescriptor, name: name) == nil {
                _ = renameat(parentDescriptor, quarantine, parentDescriptor, name)
            }
            return
        }
        _ = unlinkat(parentDescriptor, quarantine, 0)
    }

    private struct Identity: Equatable, Sendable {
        let device: UInt64
        let inode: UInt64
        let size: Int64
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64
        let changedSeconds: Int64
        let changedNanoseconds: Int64
        let kind: mode_t

        init(_ info: stat) {
            device = UInt64(info.st_dev)
            inode = UInt64(info.st_ino)
            size = info.st_size
            modifiedSeconds = info.st_mtimespec.tv_sec
            modifiedNanoseconds = info.st_mtimespec.tv_nsec
            changedSeconds = info.st_ctimespec.tv_sec
            changedNanoseconds = info.st_ctimespec.tv_nsec
            kind = info.st_mode & S_IFMT
        }

        var isDirectory: Bool { kind == S_IFDIR }
        var isRegularFile: Bool { kind == S_IFREG }
    }

    private static func identity(at url: URL) -> Identity? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        return Identity(info)
    }

    private static func identity(of descriptor: Int32) -> Identity? {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { return nil }
        return Identity(info)
    }

    private static func identity(at descriptor: Int32, name: String) -> Identity? {
        var info = stat()
        guard fstatat(descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { return nil }
        return Identity(info)
    }

    /// The directory identity only when every path component from `/` is a
    /// real directory rather than a symbolic link.
    private static func directoryIdentity(at url: URL) -> Identity? {
        var current = URL(fileURLWithPath: "/", isDirectory: true)
        guard var found = identity(at: current), found.isDirectory else { return nil }
        for component in url.standardizedFileURL.pathComponents.dropFirst() {
            current.append(path: component, directoryHint: .isDirectory)
            guard let next = identity(at: current), next.isDirectory else { return nil }
            found = next
        }
        return found
    }
}
