internal import CmuxAgentChat
internal import Darwin
internal import Foundation
internal import UniformTypeIdentifiers

/// Reads authorized content and derives fingerprints from the same filesystem metadata.
struct WorkspaceChangesContentReader: Sendable {
    /// Reads artifact metadata and its size-and-mtime fingerprint.
    func stat(path: String) throws -> WorkspaceChangesFileStat {
        guard let metadata = metadata(path: path) else {
            throw ArtifactByteReader.Error.fileNotFound
        }
        let fileType = metadata.st_mode & mode_t(S_IFMT)
        let isDirectory = fileType == mode_t(S_IFDIR)
        let isRegularFile = fileType == mode_t(S_IFREG)
        let modifiedAt = Date(
            timeIntervalSince1970: TimeInterval(metadata.st_mtimespec.tv_sec)
                + TimeInterval(metadata.st_mtimespec.tv_nsec) / 1_000_000_000
        )
        let artifactStat = ChatArtifactStat(
            exists: true,
            isDirectory: isDirectory,
            size: max(Int64(metadata.st_size), 0),
            modifiedAt: modifiedAt,
            kind: ArtifactByteReader().kind(path: path, isDirectory: isDirectory),
            mimeType: mimeType(path: path, isDirectory: isDirectory)
        )
        guard isDirectory || isRegularFile else {
            return WorkspaceChangesFileStat(
                artifactStat: artifactStat,
                contentFingerprint: nil
            )
        }
        return WorkspaceChangesFileStat(
            artifactStat: artifactStat,
            contentFingerprint: fingerprint(metadata: metadata)
        )
    }

    /// Reads one chunk and fingerprints the same opened descriptor used for sizing.
    func fetch(path: String, offset: Int64, length: Int) throws -> WorkspaceChangesFileChunk {
        let descriptor = Darwin.open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw ArtifactByteReader.Error.fileNotFound
        }
        var metadata = Darwin.stat()
        guard Darwin.fstat(descriptor, &metadata) == 0 else {
            Darwin.close(descriptor)
            throw ArtifactByteReader.Error.fileNotFound
        }
        guard metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            Darwin.close(descriptor)
            throw ArtifactByteReader.Error.unsupportedMedia
        }
        let flags = Darwin.fcntl(descriptor, F_GETFL, 0)
        guard flags >= 0,
              Darwin.fcntl(descriptor, F_SETFL, flags & ~O_NONBLOCK) >= 0 else {
            Darwin.close(descriptor)
            throw ArtifactByteReader.Error.fileNotFound
        }

        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        let totalSize = max(Int64(metadata.st_size), 0)
        let clampedOffset = min(max(offset, 0), totalSize)
        try handle.seek(toOffset: UInt64(clampedOffset))
        let data = try handle.read(upToCount: max(0, length)) ?? Data()
        let artifactChunk = ChatArtifactChunk(
            data: data,
            offset: clampedOffset,
            totalSize: totalSize,
            eof: clampedOffset + Int64(data.count) >= totalSize
        )
        return WorkspaceChangesFileChunk(
            artifactChunk: artifactChunk,
            contentFingerprint: fingerprint(metadata: metadata)
        )
    }

    /// Returns a fingerprint for a path that still exists, otherwise `nil`.
    func contentFingerprint(path: String) -> String? {
        guard let metadata = metadata(path: path) else { return nil }
        return fingerprint(metadata: metadata)
    }

    private func metadata(path: String) -> Darwin.stat? {
        let descriptor = Darwin.open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        defer { Darwin.close(descriptor) }
        var metadata = Darwin.stat()
        guard Darwin.fstat(descriptor, &metadata) == 0 else { return nil }
        return metadata
    }

    private func fingerprint(metadata: Darwin.stat) -> String {
        "\(max(Int64(metadata.st_size), 0)):\(metadata.st_mtimespec.tv_sec):\(metadata.st_mtimespec.tv_nsec)"
    }

    private func mimeType(path: String, isDirectory: Bool) -> String? {
        guard !isDirectory else { return nil }
        let fileExtension = URL(fileURLWithPath: path).pathExtension
        guard !fileExtension.isEmpty else { return nil }
        return UTType(filenameExtension: fileExtension)?.preferredMIMEType
    }
}
