internal import Darwin
internal import Foundation

/// An open descriptor for the directory in which cmux created an owned image.
///
/// Cleanup uses this descriptor with `*at(2)` operations, so renaming or
/// replacing a pathname component above the directory cannot retarget it.
final class TerminalPasteboardTemporaryImageParentDirectory:
    @unchecked Sendable
{
    let normalizedPath: String
    let descriptor: Int32

    init?(opening directoryURL: URL) {
        guard directoryURL.isFileURL else { return nil }
        let normalizedURL = directoryURL.standardizedFileURL
        let descriptor = normalizedURL.withUnsafeFileSystemRepresentation {
            path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(
                path,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard descriptor >= 0 else { return nil }

        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
            Darwin.close(descriptor)
            return nil
        }

        normalizedPath = normalizedURL.path
        self.descriptor = descriptor
    }

    deinit {
        Darwin.close(descriptor)
    }
}

/// A private directory into which a candidate entry is atomically moved
/// before its identity is verified and deleted.
final class TerminalPasteboardTemporaryImageCleanupQuarantine:
    @unchecked Sendable
{
    let directoryURL: URL
    let descriptor: Int32

    init?(inside temporaryDirectory: URL) {
        guard let created = Self.createPrivateDirectory(
            inside: temporaryDirectory.standardizedFileURL
        ) else {
            return nil
        }
        directoryURL = created.url
        descriptor = created.descriptor
    }

    deinit {
        Darwin.close(descriptor)
        directoryURL.withUnsafeFileSystemRepresentation { path in
            guard let path else { return }
            _ = Darwin.rmdir(path)
        }
    }

    private static func createPrivateDirectory(
        inside temporaryDirectory: URL
    ) -> (url: URL, descriptor: Int32)? {
        guard temporaryDirectory.isFileURL else { return nil }
        for _ in 0..<8 {
            let directoryURL = temporaryDirectory.appendingPathComponent(
                ".cmux-image-cleanup-\(UUID().uuidString)",
                isDirectory: true
            )
            let didCreate = directoryURL.withUnsafeFileSystemRepresentation {
                path in
                guard let path else { return false }
                return Darwin.mkdir(
                    path,
                    mode_t(S_IRWXU)
                ) == 0
            }
            guard didCreate else {
                if errno == EEXIST {
                    continue
                }
                return nil
            }

            let descriptor = directoryURL.withUnsafeFileSystemRepresentation {
                path -> Int32 in
                guard let path else { return -1 }
                return Darwin.open(
                    path,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                )
            }
            var metadata = stat()
            guard descriptor >= 0,
                  Darwin.fstat(descriptor, &metadata) == 0,
                  metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
                  metadata.st_uid == Darwin.geteuid(),
                  metadata.st_mode & mode_t(0o077) == 0 else {
                if descriptor >= 0 {
                    Darwin.close(descriptor)
                }
                directoryURL.withUnsafeFileSystemRepresentation { path in
                    guard let path else { return }
                    _ = Darwin.rmdir(path)
                }
                return nil
            }
            return (directoryURL, descriptor)
        }
        return nil
    }
}

/// The filesystem identity of an owned temporary image directory entry.
///
/// Device, inode, generation, and file type come from `fstatat(2)` without
/// following links. Cleanup first atomically moves the current entry into a
/// private quarantine, then verifies that complete identity there. The
/// pathname being deleted is therefore no longer the caller-visible pathname
/// that another thread can replace between verification and unlink.
struct TerminalPasteboardTemporaryImageFileIdentity: Equatable, Sendable {
    let normalizedPath: String
    let entryName: String
    let device: UInt64
    let inode: UInt64
    let generation: UInt64
    let fileType: UInt32
    private let parentDirectory:
        TerminalPasteboardTemporaryImageParentDirectory

    init?(
        capturing fileURL: URL,
        parentDirectory: TerminalPasteboardTemporaryImageParentDirectory
    ) {
        guard fileURL.isFileURL else { return nil }
        let normalizedURL = fileURL.standardizedFileURL
        let entryName = normalizedURL.lastPathComponent
        guard !entryName.isEmpty,
              entryName != ".",
              entryName != ".." else {
            return nil
        }
        guard normalizedURL.deletingLastPathComponent().path
            == parentDirectory.normalizedPath else {
            return nil
        }

        var metadata = stat()
        let didReadMetadata = entryName.withCString { name in
            Darwin.fstatat(
                parentDirectory.descriptor,
                name,
                &metadata,
                AT_SYMLINK_NOFOLLOW
            ) == 0
        }
        let fileType = metadata.st_mode & mode_t(S_IFMT)
        guard didReadMetadata, fileType == mode_t(S_IFREG) else {
            return nil
        }

        normalizedPath = normalizedURL.path
        self.entryName = entryName
        device = UInt64(metadata.st_dev)
        inode = UInt64(metadata.st_ino)
        generation = UInt64(metadata.st_gen)
        self.fileType = UInt32(fileType)
        self.parentDirectory = parentDirectory
    }

    static func == (
        lhs: TerminalPasteboardTemporaryImageFileIdentity,
        rhs: TerminalPasteboardTemporaryImageFileIdentity
    ) -> Bool {
        lhs.normalizedPath == rhs.normalizedPath
            && lhs.device == rhs.device
            && lhs.inode == rhs.inode
            && lhs.generation == rhs.generation
            && lhs.fileType == rhs.fileType
    }

    func stillNamesEntry(at fileURL: URL) -> Bool {
        guard fileURL.standardizedFileURL.path == normalizedPath else {
            return false
        }
        var metadata = stat()
        let didReadMetadata = entryName.withCString { name in
            Darwin.fstatat(
                parentDirectory.descriptor,
                name,
                &metadata,
                AT_SYMLINK_NOFOLLOW
            ) == 0
        }
        return didReadMetadata && matches(metadata)
    }

    /// Atomically removes the caller-visible name before verifying and
    /// deleting the entry. A mismatched entry is restored with
    /// `RENAME_EXCL`; if its original name was concurrently occupied, it is
    /// retained in quarantine instead of being deleted.
    @discardableResult
    func quarantineAndUnlinkIfStillOwned(
        at fileURL: URL,
        quarantine: TerminalPasteboardTemporaryImageCleanupQuarantine,
        afterQuarantineValidation: () -> Void = {}
    ) -> Bool {
        guard fileURL.standardizedFileURL.path == normalizedPath else {
            return false
        }
        let quarantineName = UUID().uuidString
        let didQuarantine = entryName.withCString { sourceName in
            quarantineName.withCString { destinationName in
                Darwin.renameatx_np(
                    parentDirectory.descriptor,
                    sourceName,
                    quarantine.descriptor,
                    destinationName,
                    UInt32(RENAME_EXCL)
                ) == 0
            }
        }
        guard didQuarantine else { return false }

        var shouldRestore = true
        defer {
            if shouldRestore {
                quarantineName.withCString { sourceName in
                    entryName.withCString { destinationName in
                        _ = Darwin.renameatx_np(
                            quarantine.descriptor,
                            sourceName,
                            parentDirectory.descriptor,
                            destinationName,
                            UInt32(RENAME_EXCL)
                        )
                    }
                }
            }
        }

        var metadata = stat()
        let didReadMetadata = quarantineName.withCString { name in
            Darwin.fstatat(
                quarantine.descriptor,
                name,
                &metadata,
                AT_SYMLINK_NOFOLLOW
            ) == 0
        }
        guard didReadMetadata, matches(metadata) else {
            return false
        }

        afterQuarantineValidation()
        let didUnlink = quarantineName.withCString { name in
            Darwin.unlinkat(quarantine.descriptor, name, 0) == 0
        }
        if didUnlink {
            shouldRestore = false
        }
        return didUnlink
    }

    private func matches(_ metadata: stat) -> Bool {
        UInt64(metadata.st_dev) == device
            && UInt64(metadata.st_ino) == inode
            && UInt64(metadata.st_gen) == generation
            && UInt32(metadata.st_mode & mode_t(S_IFMT)) == fileType
    }
}
