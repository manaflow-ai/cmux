import Darwin
import Foundation

/// Stages source bytes once so validation, hashing, and persistence agree.
struct ArtifactSourceSnapshotter {
    let fileManager: FileManager
    let chunkSize = 64 * 1024

    func snapshot(
        source: URL,
        paths: ArtifactStorePaths,
        configuration: ArtifactCaptureConfiguration,
        maximumBytes: Int64?,
        stagedURL: URL,
        expectedCanonicalPath: String? = nil,
        stagingLease: ArtifactImportStagingLease? = nil
    ) throws -> ArtifactSourceSnapshot {
        try Task.checkCancellation()
        let normalizedConfiguration = configuration.normalized
        let pathExtension = source.pathExtension.lowercased()
        guard normalizedConfiguration.allowedExtensions.contains(pathExtension) else {
            throw ArtifactStoreError.unsupportedExtension(pathExtension)
        }
        let limit = ArtifactFileKind(fileURL: source) == .text
            ? normalizedConfiguration.maximumTextFileBytes
            : normalizedConfiguration.maximumFileBytes
        let batchLimit = maximumBytes.map { max(0, $0) }

        try rejectSymbolicLink(at: paths.importStagingRoot)
        try fileManager.createDirectory(at: paths.importStagingRoot, withIntermediateDirectories: true)
        try rejectSymbolicLink(at: paths.importStagingRoot)
        let sourceDescriptor = open(
            source.path,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK
        )
        guard sourceDescriptor >= 0 else {
            throw ArtifactStoreError.sourceNotRegularFile(source.path)
        }
        let sourceHandle = FileHandle(fileDescriptor: sourceDescriptor, closeOnDealloc: true)
        defer { try? sourceHandle.close() }

        var sourceStatus = stat()
        guard fstat(sourceDescriptor, &sourceStatus) == 0,
              (sourceStatus.st_mode & S_IFMT) == S_IFREG else {
            throw ArtifactStoreError.sourceNotRegularFile(source.path)
        }
        if let expectedCanonicalPath {
            let resolver = ArtifactPathResolver(fileManager: fileManager)
            guard let openedPath = openedPath(for: sourceDescriptor),
                  resolver.canonicalPath(URL(fileURLWithPath: openedPath))
                    == expectedCanonicalPath else {
                throw ArtifactStoreError.pathOutsideStore(source.path)
            }
        }
        guard sourceStatus.st_size <= limit else {
            throw ArtifactStoreError.fileTooLarge(actual: sourceStatus.st_size, limit: limit)
        }
        if let batchLimit, sourceStatus.st_size > batchLimit {
            throw ArtifactStoreError.batchByteLimitReached(
                actual: sourceStatus.st_size,
                limit: batchLimit
            )
        }

        let stagedDescriptor: Int32
        if let stagingLease {
            stagedDescriptor = stagingLease.openStagedFile(for: stagedURL) ?? -1
        } else {
            stagedDescriptor = open(
                stagedURL.path,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                S_IRUSR | S_IWUSR
            )
        }
        guard stagedDescriptor >= 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
        let stagedHandle = FileHandle(fileDescriptor: stagedDescriptor, closeOnDealloc: true)
        var keepsStagedFile = false
        defer {
            try? stagedHandle.close()
            if !keepsStagedFile {
                if let stagingLease {
                    stagingLease.removeStagedFile(for: stagedURL)
                } else {
                    try? fileManager.removeItem(at: stagedURL)
                }
            }
        }

        var size: Int64 = 0
        while true {
            try Task.checkCancellation()
            guard let data = try sourceHandle.read(upToCount: chunkSize), !data.isEmpty else { break }
            size += Int64(data.count)
            guard size <= limit else {
                throw ArtifactStoreError.fileTooLarge(actual: size, limit: limit)
            }
            if let batchLimit, size > batchLimit {
                throw ArtifactStoreError.batchByteLimitReached(actual: size, limit: batchLimit)
            }
            try stagedHandle.write(contentsOf: data)
        }
        try stagedHandle.synchronize()
        try stagedHandle.close()
        keepsStagedFile = true
        return ArtifactSourceSnapshot(url: stagedURL, size: size)
    }

    private func rejectSymbolicLink(at url: URL) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard values.isSymbolicLink != true else {
            throw ArtifactStoreError.pathOutsideStore(url.path)
        }
    }

    /// Returns the kernel-resolved path for an already-open descriptor.
    ///
    /// Validating the descriptor after O_NOFOLLOW closes the parent symlink
    /// TOCTOU window: a swapped directory can no longer redirect the bytes we
    /// stage without producing a different resolved path.
    private func openedPath(for descriptor: Int32) -> String? {
        var buffer = [UInt8](repeating: 0, count: Int(PATH_MAX))
        let result = buffer.withUnsafeMutableBytes { bytes in
            fcntl(descriptor, F_GETPATH, bytes.baseAddress)
        }
        guard result == 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
    }
}
