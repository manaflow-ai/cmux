package import Darwin
package import Foundation

/// One app-local history file retained across the daemon handoff.
///
/// SAFETY: the directory descriptor and captured identities are immutable;
/// the descriptor closes only after the last reference is released.
package final class LegacyHistoryFile: Sendable, Equatable {
    package let url: URL
    private let parentURL: URL
    private let parentDescriptor: Int32
    private let parentIdentity: Identity
    private let name: String
    private let identity: Identity

    package init?(url: URL, supportDirectory: URL) {
        let support = Self.plainPath(supportDirectory, isDirectory: true)
        let candidate = Self.plainPath(url, isDirectory: false)
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

    nonisolated deinit {
        Darwin.close(parentDescriptor)
    }

    package static func == (lhs: LegacyHistoryFile, rhs: LegacyHistoryFile) -> Bool {
        lhs.url == rhs.url && lhs.parentIdentity == rhs.parentIdentity && lhs.identity == rhs.identity
    }

    /// Stable, non-secret identity used in the import idempotency key.
    package var fingerprint: String {
        "\(identity.device):\(identity.inode):\(identity.size):\(identity.modifiedSeconds):\(identity.modifiedNanoseconds):\(identity.changedSeconds):\(identity.changedNanoseconds)"
    }

    package var isUnchanged: Bool {
        Self.directoryIdentity(at: parentURL)?.isSameObject(as: parentIdentity) == true
            && Self.identity(at: parentDescriptor, name: name) == identity
    }

    package static func pathEntryExists(_ url: URL) -> Bool {
        identity(at: plainPath(url, isDirectory: false)) != nil
    }

    /// Removes a captured SQLite generation only when every present member is
    /// unchanged and every absent member is still absent. `files` is ordered
    /// sidecars first and the main database last.
    @discardableResult
    package static func removeGenerationIfUnchanged(
        _ files: [LegacyHistoryFile],
        missing: [URL]
    ) -> Bool {
        guard !files.isEmpty, files.allSatisfy(\.isUnchanged),
              missing.allSatisfy({ !pathEntryExists($0) }) else { return false }
        var quarantined: [(LegacyHistoryFile, Quarantine)] = []
        for file in files {
            guard let quarantine = file.quarantineIfUnchanged() else {
                for (moved, quarantine) in quarantined.reversed() { moved.restore(quarantine.name) }
                return false
            }
            quarantined.append((file, quarantine))
        }
        guard quarantined.allSatisfy({ $0.0.quarantinedIsUnchanged($0.1) }) else {
            for (file, quarantine) in quarantined.reversed() { file.restore(quarantine.name) }
            return false
        }
        var removed = true
        for (file, quarantine) in quarantined {
            if unlinkat(file.parentDescriptor, quarantine.name, 0) != 0 { removed = false }
        }
        return removed
    }

    @discardableResult
    package func removeIfUnchanged() -> Bool {
        Self.removeGenerationIfUnchanged([self], missing: [])
    }

    /// A file moved aside for removal, with its identity as of the move.
    private struct Quarantine {
        package let name: String
        package let identity: Identity

        package init(name: String, identity: Identity) {
            self.name = name
            self.identity = identity
        }
    }

    private func quarantineIfUnchanged() -> Quarantine? {
        guard Self.directoryIdentity(at: parentURL)?.isSameObject(as: parentIdentity) == true,
              Self.identity(at: parentDescriptor, name: name) == identity else { return nil }
        let quarantine = ".cmux-history-cleanup-\(UUID().uuidString.lowercased())"
        guard renameat(parentDescriptor, name, parentDescriptor, quarantine) == 0 else { return nil }
        // The rename itself moves the change time (APFS), so the moved file matches
        // the captured one in everything else; it must then stay as it is after the move.
        guard let moved = Self.identity(at: parentDescriptor, name: quarantine), moved.isRenamed(identity) else {
            restore(quarantine)
            return nil
        }
        return Quarantine(name: quarantine, identity: moved)
    }

    private func quarantinedIsUnchanged(_ quarantine: Quarantine) -> Bool {
        Self.identity(at: parentDescriptor, name: quarantine.name) == quarantine.identity
    }

    private func restore(_ quarantine: String) {
        if Self.identity(at: parentDescriptor, name: name) == nil {
            _ = renameat(parentDescriptor, quarantine, parentDescriptor, name)
        }
    }

    private struct Identity: Equatable, Sendable {
        package let device: UInt64
        package let inode: UInt64
        package let size: Int64
        package let modifiedSeconds: Int64
        package let modifiedNanoseconds: Int64
        package let changedSeconds: Int64
        package let changedNanoseconds: Int64
        package let kind: mode_t

        package init(_ info: stat) {
            device = UInt64(info.st_dev)
            inode = UInt64(info.st_ino)
            size = info.st_size
            modifiedSeconds = Int64(info.st_mtimespec.tv_sec)
            modifiedNanoseconds = Int64(info.st_mtimespec.tv_nsec)
            changedSeconds = Int64(info.st_ctimespec.tv_sec)
            changedNanoseconds = Int64(info.st_ctimespec.tv_nsec)
            kind = info.st_mode & S_IFMT
        }

        package var isDirectory: Bool { kind == S_IFDIR }
        package var isRegularFile: Bool { kind == S_IFREG }

        package func isSameObject(as other: Identity) -> Bool {
            device == other.device && inode == other.inode && kind == other.kind
        }

        /// `other` after a rename: the same file and contents; only the change time may differ.
        package func isRenamed(_ other: Identity) -> Bool {
            isSameObject(as: other) && size == other.size
                && modifiedSeconds == other.modifiedSeconds && modifiedNanoseconds == other.modifiedNanoseconds
        }
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

    /// `url` as the file system sees it, with `.` and `..` collapsed. Rebuilt from the
    /// decoded path first, so an encoded `%2E%2E` collapses too and an encoded `%2F` stays
    /// part of one name. Not `standardizedFileURL`: it also drops a leading /private,
    /// turning /private/var/… into /var/…, a link that cleanup refuses.
    private static func plainPath(_ url: URL, isDirectory: Bool) -> URL {
        URL(fileURLWithPath: url.path, isDirectory: isDirectory).standardized
    }

    /// The directory identity only when every path component from `/` is a
    /// real directory rather than a symbolic link.
    private static func directoryIdentity(at url: URL) -> Identity? {
        var current = URL(fileURLWithPath: "/", isDirectory: true)
        guard var found = identity(at: current), found.isDirectory else { return nil }
        for component in plainPath(url, isDirectory: true).pathComponents.dropFirst() {
            current.append(path: component, directoryHint: .isDirectory)
            guard let next = identity(at: current), next.isDirectory else { return nil }
            found = next
        }
        return found
    }
}
