import Darwin
import Foundation
import os

nonisolated private let helperStagingLogger = Logger(
    subsystem: "com.cmuxterm.app",
    category: "ComputerUseHelperStaging"
)

/// Owns the standalone helper's staged-copy transaction and orphan cleanup.
///
/// One fixed scratch slot bounds disk use even when removal fails. Publication
/// exchanges the complete directories atomically, so the installed path always
/// names the old or new generation. A process lease excludes active installs
/// from both startup and scheduled cleanup.
struct ComputerUseHelperStaging {
    nonisolated private static let stagingPrefix = ".cmux Computer Use."
    nonisolated private static let appSuffix = ".app"

    nonisolated static let stagingName = ".cmux Computer Use.staging.app"

    private let fileManager: FileManager

    /// Creates a staging owner backed by the supplied file manager.
    nonisolated init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    /// Returns whether the installed bundle contains the same regular files as
    /// the nested bundle and has an executable helper binary.
    nonisolated func isCurrent(nested: URL, destination: URL) -> Bool {
        guard !Task.isCancelled else { return false }
        let nestedBinary = nested
            .appendingPathComponent("Contents/MacOS/cmux-cua")
        let destinationBinary = destination
            .appendingPathComponent("Contents/MacOS/cmux-cua")
        guard fileManager.isExecutableFile(atPath: destinationBinary.path) else {
            return false
        }
        guard
            let nestedFiles = helperBundleRelativeFilePaths(at: nested),
            let destinationFiles = helperBundleRelativeFilePaths(at: destination),
            nestedFiles == destinationFiles
        else {
            return false
        }
        for relativePath in nestedFiles {
            guard !Task.isCancelled else { return false }
            let nestedFile = nested.appendingPathComponent(relativePath, isDirectory: false)
            let destinationFile = destination.appendingPathComponent(
                relativePath,
                isDirectory: false
            )
            guard fileManager.contentsEqual(
                atPath: nestedFile.path,
                andPath: destinationFile.path
            ) else {
                return false
            }
        }
        return fileManager.contentsEqual(
            atPath: nestedBinary.path,
            andPath: destinationBinary.path
        )
    }

    /// Installs a verified helper copy, returning nil after any failed step.
    ///
    /// Failure and cancellation run writable-tree cleanup before returning.
    /// If the filesystem refuses removal, the fixed slot blocks further copies
    /// until cleanup succeeds. The old installed generation survives a failed
    /// atomic publication.
    @discardableResult
    nonisolated func install(
        nested: URL,
        destination: URL,
        directory: URL
    ) -> URL? {
        do {
            return try installVerified(nested: nested, destination: destination, directory: directory)
        } catch is CancellationError {
            return nil
        } catch {
            helperStagingLogger.error("Computer Use helper install failed (code \((error as NSError).code))")
            return nil
        }
    }

    /// Performs the transaction while preserving the filesystem error for callers.
    nonisolated func installVerified(nested: URL, destination: URL, directory: URL) throws -> URL {
        try ComputerUseHelperDirectory(fileManager: fileManager)
            .withExclusiveAccess(to: directory, createIfMissing: true) {
                try Task.checkCancellation()
                _ = reapWithoutLease(in: directory)
                let temporary = directory.appendingPathComponent(Self.stagingName, isDirectory: true)
                // Never allocate another name when a prior cleanup failed.
                guard removeStagedBundle(at: temporary) else { throw CocoaError(.fileWriteNoPermission) }
                defer { _ = removeStagedBundle(at: temporary) }
                try fileManager.copyItem(at: nested, to: temporary)
                // macOS 15 can deny renameatx_np for a read-only directory.
                // Normalize only our managed copy, never the bundled source.
                try makeDirectoriesWritable(at: temporary)
                try releaseCopiedHelperFromQuarantine(at: temporary)
                try Task.checkCancellation()
                guard isCurrent(nested: nested, destination: temporary) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                try publish(temporary: temporary, destination: destination)
                return destination
            }
    }

    /// Removes orphaned hidden staging bundles in the helper directory.
    ///
    /// Only the fixed scratch slot and legacy UUID-shaped directories are
    /// considered. Symbolic links and the published `cmux Computer Use.app`
    /// destination are left untouched.
    @discardableResult
    nonisolated func reapOrphanedBundles(in directory: URL) -> Int {
        do {
            return try ComputerUseHelperDirectory(fileManager: fileManager)
                .withExclusiveAccess(to: directory, createIfMissing: false) {
                    reapWithoutLease(in: directory)
                }
        } catch {
            return 0
        }
    }

    /// Visits legacy orphans only while holding the install/reaper lease.
    private nonisolated func reapWithoutLease(in directory: URL) -> Int {
        guard !Task.isCancelled else { return 0 }
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [],
            options: []
        ) else {
            return 0
        }

        var removedCount = 0
        for entry in entries {
            guard !Task.isCancelled else { break }
            guard isStagingBundleName(entry.lastPathComponent),
                  isDirectoryWithoutFollowingSymlinks(entry)
            else {
                continue
            }
            if removeStagedBundle(at: entry) {
                removedCount += 1
            }
        }
        return removedCount
    }

    /// Removes quarantine attributes from a copied helper tree.
    @discardableResult
    nonisolated func releaseCopiedHelperFromQuarantine(
        at url: URL
    ) throws -> ComputerUseHelperQuarantineRelease.Report {
        let report = try ComputerUseHelperQuarantineRelease(fileManager: fileManager)
            .release(treeAt: url)
        for failure in report.failures {
            helperStagingLogger.error(
                "Computer Use helper quarantine release failed for \(failure.url.lastPathComponent, privacy: .public) (errno \(failure.code))"
            )
        }
        return report
    }

    /// Atomically publishes the candidate; on failure the old generation stays installed.
    private nonisolated func publish(temporary: URL, destination: URL) throws {
        try Task.checkCancellation()
        let exists = modeBits(at: destination) != nil
        if exists { try makeDirectoriesWritable(at: destination) }
        let flags = UInt32(exists ? RENAME_SWAP : RENAME_EXCL)
        guard renameatx_np(AT_FDCWD, temporary.path, AT_FDCWD, destination.path, flags) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        // After a swap, the old installed tree occupies the same fixed scratch
        // slot. Deferred cleanup or the next pass removes it, even after exit.
    }

    /// Makes a staging tree removable and deletes it, logging only a safe bundle name and error code.
    private nonisolated func removeStagedBundle(at url: URL) -> Bool {
        guard modeBits(at: url) != nil else { return true }
        do {
            try makeDirectoriesWritable(at: url)
            try fileManager.removeItem(at: url)
            return true
        } catch {
            let errorCode = (error as NSError).code
            helperStagingLogger.error(
                "Computer Use helper staging cleanup failed for \(url.lastPathComponent, privacy: .public) (code \(errorCode))"
            )
            return false
        }
    }

    /// Restores owner write and search permission on every directory in a staging tree.
    private nonisolated func makeDirectoriesWritable(at root: URL) throws {
        guard let mode = modeBits(at: root), mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
            return
        }
        // Open without following links before changing permissions. Repair the
        // parent before listing its children, without following any links.
        let descriptor = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_uid == geteuid() else {
            throw POSIXError(.EPERM)
        }
        if metadata.st_mode & 0o700 != 0o700 {
            guard fchmod(descriptor, (metadata.st_mode & 0o777) | 0o700) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
        for name in try fileManager.contentsOfDirectory(atPath: root.path) {
            try makeDirectoriesWritable(at: root.appendingPathComponent(name))
        }
    }

    /// Returns whether a name is an exact UUID-shaped hidden staging bundle name.
    private nonisolated func isStagingBundleName(_ name: String) -> Bool {
        if name == Self.stagingName { return true }
        guard name.hasPrefix(Self.stagingPrefix), name.hasSuffix(Self.appSuffix) else {
            return false
        }
        guard name.count > Self.stagingPrefix.count + Self.appSuffix.count else {
            return false
        }
        let start = name.index(name.startIndex, offsetBy: Self.stagingPrefix.count)
        let end = name.index(name.endIndex, offsetBy: -Self.appSuffix.count)
        guard start < end else { return false }
        let identifier = String(name[start ..< end])
        return UUID(uuidString: identifier) != nil
    }

    /// Checks a path's directory type without following symbolic links.
    private nonisolated func isDirectoryWithoutFollowingSymlinks(_ url: URL) -> Bool {
        modeBits(at: url).map {
            $0 & mode_t(S_IFMT) == mode_t(S_IFDIR)
        } ?? false
    }

    /// Reads POSIX mode bits with `lstat(2)`.
    private nonisolated func modeBits(at url: URL) -> mode_t? {
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return nil }
            var metadata = stat()
            guard lstat(path, &metadata) == 0 else { return nil }
            return metadata.st_mode
        }
    }

    /// Lists regular files used to verify a copied helper bundle.
    private nonisolated func helperBundleRelativeFilePaths(at root: URL) -> Set<String>? {
        var enumerationFailed = false
        guard
            let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [],
                errorHandler: { _, _ in
                    enumerationFailed = true
                    return false
                }
            )
        else {
            return nil
        }
        var paths: Set<String> = []
        for case let fileURL as URL in enumerator {
            guard !Task.isCancelled else { return nil }
            guard
                let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]),
                values.isRegularFile == true
            else {
                continue
            }
            let relativePath = String(fileURL.path.dropFirst(root.path.count + 1))
            paths.insert(relativePath)
        }
        return enumerationFailed ? nil : paths
    }
}
