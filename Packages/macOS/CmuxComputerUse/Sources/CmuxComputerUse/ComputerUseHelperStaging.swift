import Darwin
import Foundation
import os

private let helperStagingLogger = Logger(
    subsystem: "com.cmuxterm.app",
    category: "ComputerUseHelperStaging"
)

/// Owns the standalone helper's staged-copy transaction and orphan cleanup.
///
/// A copied app bundle can preserve read-only directory modes from the nested
/// bundle. Cleanup therefore makes only the staging tree's directories
/// owner-writable before removing it. Published bundles are moved within the
/// same parent directory so the final rename is atomic when no previous bundle
/// exists, and a previous bundle is retained under the same reapable name until
/// the replacement has been published.
struct ComputerUseHelperStaging {
    private static let stagingPrefix = ".cmux Computer Use."
    private static let appSuffix = ".app"

    private let fileManager: FileManager

    /// Creates a staging owner backed by the supplied file manager.
    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    /// Returns whether the installed bundle contains the same regular files as
    /// the nested bundle and has an executable helper binary.
    func isCurrent(nested: URL, destination: URL) -> Bool {
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
    /// The temporary bundle is always removed on a thrown error or
    /// cancellation. The source and staged trees are compared before the
    /// staged directory is renamed into the destination path.
    @discardableResult
    func install(
        nested: URL,
        destination: URL,
        directory: URL
    ) -> URL? {
        let temporary = directory.appendingPathComponent(
            "\(Self.stagingPrefix)\(UUID().uuidString)\(Self.appSuffix)",
            isDirectory: true
        )
        do {
            guard !Task.isCancelled else { return nil }
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            _ = reapOrphanedBundles(in: directory)
            defer { _ = removeStagedBundle(at: temporary) }
            try fileManager.copyItem(at: nested, to: temporary)
            try releaseCopiedHelperFromQuarantine(at: temporary)
            guard !Task.isCancelled, isCurrent(nested: nested, destination: temporary) else {
                return nil
            }
            try publish(temporary: temporary, destination: destination, directory: directory)
            return destination
        } catch is CancellationError {
            return nil
        } catch {
            return nil
        }
    }

    /// Removes orphaned hidden staging bundles in the helper directory.
    ///
    /// Only UUID-shaped directories with the exact cmux staging prefix are
    /// considered. Symbolic links and the published `cmux Computer Use.app`
    /// destination are left untouched.
    @discardableResult
    func reapOrphanedBundles(in directory: URL) -> Int {
        guard !Task.isCancelled,
              isDirectoryWithoutFollowingSymlinks(directory)
        else {
            return 0
        }
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [],
            options: []
        ) else {
            return 0
        }

        var removedCount = 0
        for entry in entries {
            guard !Task.isCancelled,
                  isStagingBundleName(entry.lastPathComponent),
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
    func releaseCopiedHelperFromQuarantine(
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

    private func publish(
        temporary: URL,
        destination: URL,
        directory: URL
    ) throws {
        guard !Task.isCancelled else { throw CancellationError() }
        let previous = directory.appendingPathComponent(
            "\(Self.stagingPrefix)\(UUID().uuidString)\(Self.appSuffix)",
            isDirectory: true
        )
        var movedPrevious = false
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.moveItem(at: destination, to: previous)
            movedPrevious = true
        }
        do {
            guard !Task.isCancelled else { throw CancellationError() }
            try fileManager.moveItem(at: temporary, to: destination)
        } catch {
            if movedPrevious {
                try? fileManager.moveItem(at: previous, to: destination)
            }
            throw error
        }
        if movedPrevious {
            _ = removeStagedBundle(at: previous)
        }
    }

    private func removeStagedBundle(at url: URL) -> Bool {
        guard fileManager.fileExists(atPath: url.path) else { return true }
        makeDirectoriesWritable(at: url)
        do {
            try fileManager.removeItem(at: url)
            return true
        } catch {
            helperStagingLogger.error(
                "Computer Use helper staging cleanup failed for \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            return false
        }
    }

    private func makeDirectoriesWritable(at root: URL) {
        var entries = [root]
        if let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [],
            options: []
        ) {
            for case let entry as URL in enumerator {
                entries.append(entry)
            }
        }
        for entry in entries {
            guard let mode = modeBits(at: entry), mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
            else {
                continue
            }
            let permissions = mode & mode_t(0o777)
            _ = chmod(entry.path, permissions | mode_t(0o700))
        }
    }

    private func isStagingBundleName(_ name: String) -> Bool {
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

    private func isDirectoryWithoutFollowingSymlinks(_ url: URL) -> Bool {
        modeBits(at: url).map {
            $0 & mode_t(S_IFMT) == mode_t(S_IFDIR)
        } ?? false
    }

    private func modeBits(at url: URL) -> mode_t? {
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return nil }
            var metadata = stat()
            guard lstat(path, &metadata) == 0 else { return nil }
            return metadata.st_mode
        }
    }

    private func helperBundleRelativeFilePaths(at root: URL) -> Set<String>? {
        guard
            let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
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
        return paths
    }
}
