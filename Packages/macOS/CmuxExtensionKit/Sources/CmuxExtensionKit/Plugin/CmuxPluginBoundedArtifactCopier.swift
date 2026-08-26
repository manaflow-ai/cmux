import Darwin
import Foundation

/// Copies a plugin bundle with the same entry, file, and byte bounds used by
/// ``CmuxPluginArtifactFingerprinter``.
struct CmuxPluginBoundedArtifactCopier {
    private static let chunkSize = 64 * 1024
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    /// Copies only regular, non-symbolic-link files beneath `source`.
    ///
    /// Every source file is opened with `O_NOFOLLOW`, checked through its
    /// descriptor, and copied in bounded chunks. A source that grows while it
    /// is being copied fails closed instead of allowing an unbounded
    /// `FileManager.copyItem` allocation.
    func copyDirectory(from source: URL, to destination: URL) throws {
        let source = source.standardizedFileURL
        let destination = destination.standardizedFileURL
        guard let rootValues = try? source.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        ),
              rootValues.isDirectory == true,
              rootValues.isSymbolicLink != true else {
            throw CmuxPluginExecutionSnapshotError.copyFailed
        }

        try fileManager.createDirectory(
            at: destination,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        guard let enumerator = fileManager.enumerator(
            at: source,
            includingPropertiesForKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
            ],
            options: []
        ) else {
            throw CmuxPluginExecutionSnapshotError.copyFailed
        }

        var entryCount = 0
        var fileCount = 0
        var totalBytes: UInt64 = 0
        for case let sourceURL as URL in enumerator {
            guard entryCount < CmuxPluginArtifactFingerprinter.maximumArtifactEntries else {
                throw CmuxPluginExecutionSnapshotError.copyFailed
            }
            entryCount += 1

            let values = try sourceURL.resourceValues(forKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
            ])
            guard values.isSymbolicLink != true else {
                throw CmuxPluginExecutionSnapshotError.copyFailed
            }
            let relativePath = try relativePath(of: sourceURL, under: source)
            let destinationURL = destination.appendingPathComponent(
                relativePath,
                isDirectory: values.isDirectory == true
            )

            if values.isDirectory == true {
                try fileManager.createDirectory(
                    at: destinationURL,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: NSNumber(value: 0o700)]
                )
                continue
            }

            guard values.isRegularFile == true,
                  fileCount < CmuxPluginArtifactFingerprinter.maximumArtifactFiles else {
                throw CmuxPluginExecutionSnapshotError.copyFailed
            }
            fileCount += 1
            guard totalBytes <= CmuxPluginArtifactFingerprinter.maximumArtifactBytes else {
                throw CmuxPluginExecutionSnapshotError.copyFailed
            }
            let remainingBytes = CmuxPluginArtifactFingerprinter.maximumArtifactBytes - totalBytes
            let copiedBytes = try copyRegularFile(
                from: sourceURL,
                to: destinationURL,
                maximumBytes: remainingBytes
            )
            guard copiedBytes <= remainingBytes else {
                throw CmuxPluginExecutionSnapshotError.copyFailed
            }
            totalBytes += copiedBytes
        }
    }

    private func relativePath(of url: URL, under root: URL) throws -> String {
        let rootPath = root.path
        let candidatePath = url.standardizedFileURL.path
        guard candidatePath.hasPrefix(rootPath + "/") else {
            throw CmuxPluginExecutionSnapshotError.copyFailed
        }
        let relativePath = String(candidatePath.dropFirst(rootPath.count + 1))
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty,
              components.allSatisfy({ $0 != "." && $0 != ".." && !$0.isEmpty }) else {
            throw CmuxPluginExecutionSnapshotError.copyFailed
        }
        return relativePath
    }

    private func copyRegularFile(
        from source: URL,
        to destination: URL,
        maximumBytes: UInt64
    ) throws -> UInt64 {
        let sourceDescriptor = Darwin.open(
            source.path,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK
        )
        guard sourceDescriptor >= 0 else {
            throw CmuxPluginExecutionSnapshotError.copyFailed
        }
        defer { Darwin.close(sourceDescriptor) }

        var initialMetadata = Darwin.stat()
        guard Darwin.fstat(sourceDescriptor, &initialMetadata) == 0,
              (initialMetadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              initialMetadata.st_size >= 0,
              UInt64(initialMetadata.st_size) <= maximumBytes else {
            throw CmuxPluginExecutionSnapshotError.copyFailed
        }

        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        let destinationDescriptor = Darwin.open(
            destination.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            mode_t(0o600)
        )
        guard destinationDescriptor >= 0 else {
            throw CmuxPluginExecutionSnapshotError.copyFailed
        }
        defer { Darwin.close(destinationDescriptor) }

        let sourceHandle = FileHandle(fileDescriptor: sourceDescriptor, closeOnDealloc: false)
        let destinationHandle = FileHandle(
            fileDescriptor: destinationDescriptor,
            closeOnDealloc: false
        )
        var copiedBytes: UInt64 = 0
        do {
            while let chunk = try sourceHandle.read(upToCount: Self.chunkSize), !chunk.isEmpty {
                guard UInt64(chunk.count) <= maximumBytes - copiedBytes else {
                    throw CmuxPluginExecutionSnapshotError.copyFailed
                }
                try destinationHandle.write(contentsOf: chunk)
                copiedBytes += UInt64(chunk.count)
            }
        } catch {
            throw CmuxPluginExecutionSnapshotError.copyFailed
        }

        var finalMetadata = Darwin.stat()
        guard Darwin.fstat(sourceDescriptor, &finalMetadata) == 0,
              finalMetadata.st_size >= 0,
              UInt64(finalMetadata.st_size) == copiedBytes,
              UInt64(initialMetadata.st_size) == copiedBytes,
              Darwin.fchmod(
                  destinationDescriptor,
                  mode_t(initialMetadata.st_mode & mode_t(0o777))
              ) == 0 else {
            throw CmuxPluginExecutionSnapshotError.copyFailed
        }
        return copiedBytes
    }
}
