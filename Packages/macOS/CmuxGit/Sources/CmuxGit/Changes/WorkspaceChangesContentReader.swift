internal import CmuxAgentChat
internal import Darwin
internal import Foundation
internal import UniformTypeIdentifiers

/// Reads authorized content and derives fingerprints from the same filesystem metadata.
struct WorkspaceChangesContentReader: Sendable, WorkspaceChangesContentFingerprintReading {
    private let regularFileOpener = WorkspaceChangesRegularFileOpener()

    /// Reads artifact metadata and its identity-bearing filesystem fingerprint.
    func stat(repoRoot: String, relativePath: String) throws -> WorkspaceChangesFileStat {
        let openedFile = try regularFileOpener.open(
            repoRoot: repoRoot,
            relativePath: relativePath
        )
        Darwin.close(openedFile.descriptor)
        let metadata = openedFile.metadata
        let modifiedAt = Date(
            timeIntervalSince1970: TimeInterval(metadata.st_mtimespec.tv_sec)
                + TimeInterval(metadata.st_mtimespec.tv_nsec) / 1_000_000_000
        )
        let path = URL(fileURLWithPath: repoRoot, isDirectory: true)
            .appendingPathComponent(relativePath, isDirectory: false)
            .path
        let artifactStat = ChatArtifactStat(
            exists: true,
            isDirectory: false,
            size: max(Int64(metadata.st_size), 0),
            modifiedAt: modifiedAt,
            kind: ArtifactByteReader().kind(path: path, isDirectory: false),
            mimeType: mimeType(path: path)
        )
        return WorkspaceChangesFileStat(
            artifactStat: artifactStat,
            contentFingerprint: fingerprint(metadata: metadata)
        )
    }

    /// Reads one chunk and fingerprints the same opened descriptor used for sizing.
    func fetch(
        repoRoot: String,
        relativePath: String,
        offset: Int64,
        length: Int
    ) throws -> WorkspaceChangesFileChunk {
        let openedFile = try regularFileOpener.open(
            repoRoot: repoRoot,
            relativePath: relativePath
        )
        let descriptor = openedFile.descriptor
        let metadata = openedFile.metadata
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
        var postReadMetadata = Darwin.stat()
        guard Darwin.fstat(descriptor, &postReadMetadata) == 0 else {
            throw WorkspaceChangesServiceError.gitFailure
        }
        try validateStableMetadata(before: metadata, after: postReadMetadata)
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

    /// Returns an identity-bearing filesystem fingerprint for an existing path.
    func contentFingerprint(repoRoot: String, relativePath: String) -> String? {
        guard let openedFile = try? regularFileOpener.open(
            repoRoot: repoRoot,
            relativePath: relativePath
        ) else { return nil }
        Darwin.close(openedFile.descriptor)
        return fingerprint(metadata: openedFile.metadata)
    }

    /// Rejects chunks read while the opened file's identity or metadata changed.
    func validateStableMetadata(before: Darwin.stat, after: Darwin.stat) throws {
        guard before.st_dev == after.st_dev,
              before.st_ino == after.st_ino,
              before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else {
            throw WorkspaceChangesServiceError.gitFailure
        }
    }

    private func fingerprint(metadata: Darwin.stat) -> String {
        let modifiedAtNanoseconds =
            Int64(metadata.st_mtimespec.tv_sec) * 1_000_000_000
            + Int64(metadata.st_mtimespec.tv_nsec)
        let statusChangedAtNanoseconds =
            Int64(metadata.st_ctimespec.tv_sec) * 1_000_000_000
            + Int64(metadata.st_ctimespec.tv_nsec)
        return "stat:\(max(Int64(metadata.st_size), 0)):\(modifiedAtNanoseconds):"
            + "\(metadata.st_dev):\(metadata.st_ino):\(statusChangedAtNanoseconds)"
    }

    private func mimeType(path: String) -> String? {
        let fileExtension = URL(fileURLWithPath: path).pathExtension
        guard !fileExtension.isEmpty else { return nil }
        return UTType(filenameExtension: fileExtension)?.preferredMIMEType
    }
}
