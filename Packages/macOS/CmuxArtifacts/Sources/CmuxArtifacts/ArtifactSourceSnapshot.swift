import Darwin
import Foundation

/// Immutable, size-bounded copy of one import source.
struct ArtifactSourceSnapshot {
    let url: URL
    let size: Int64
}

/// Stages source bytes once so validation, hashing, and persistence agree.
struct ArtifactSourceSnapshotter {
    let fileManager: FileManager
    let chunkSize = 64 * 1024

    func snapshot(
        source: URL,
        paths: ArtifactStorePaths,
        configuration: ArtifactCaptureConfiguration,
        stagedURL: URL
    ) throws -> ArtifactSourceSnapshot {
        try Task.checkCancellation()
        let normalizedConfiguration = configuration.normalized
        let pathExtension = source.pathExtension.lowercased()
        guard normalizedConfiguration.allowedExtensions.contains(pathExtension) else {
            throw ArtifactStoreError.unsupportedExtension(pathExtension)
        }
        let limit = ArtifactFileKind.classify(source) == .text
            ? normalizedConfiguration.maximumTextFileBytes
            : normalizedConfiguration.maximumFileBytes

        try rejectSymbolicLink(at: paths.importStagingRoot)
        try fileManager.createDirectory(at: paths.importStagingRoot, withIntermediateDirectories: true)
        try rejectSymbolicLink(at: paths.importStagingRoot)
        let sourceDescriptor = open(source.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
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

        let stagedDescriptor = open(
            stagedURL.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard stagedDescriptor >= 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
        let stagedHandle = FileHandle(fileDescriptor: stagedDescriptor, closeOnDealloc: true)
        var keepsStagedFile = false
        defer {
            try? stagedHandle.close()
            if !keepsStagedFile { try? fileManager.removeItem(at: stagedURL) }
        }

        var size: Int64 = 0
        while true {
            try Task.checkCancellation()
            guard let data = try sourceHandle.read(upToCount: chunkSize), !data.isEmpty else { break }
            size += Int64(data.count)
            guard size <= limit else {
                throw ArtifactStoreError.fileTooLarge(actual: size, limit: limit)
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
}
