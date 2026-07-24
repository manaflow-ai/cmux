internal import CmuxAgentChat
internal import Darwin
internal import Foundation
internal import UniformTypeIdentifiers

/// Reads authorized content and derives fingerprints from the same filesystem metadata.
struct WorkspaceChangesContentReader: Sendable {
    /// Reads artifact metadata and its size-and-mtime fingerprint.
    func stat(repoRoot: String, relativePath: String) throws -> WorkspaceChangesFileStat {
        let openedFile = try openRegularFile(repoRoot: repoRoot, relativePath: relativePath)
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
        let openedFile = try openRegularFile(repoRoot: repoRoot, relativePath: relativePath)
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
    func contentFingerprint(repoRoot: String, relativePath: String) -> String? {
        guard let openedFile = try? openRegularFile(
            repoRoot: repoRoot,
            relativePath: relativePath
        ) else { return nil }
        Darwin.close(openedFile.descriptor)
        return fingerprint(metadata: openedFile.metadata)
    }

    /// Resolves the fingerprint returned with a captured diff.
    func fileDiffFingerprint(before: String?, after: String?) -> String? {
        // A size-and-mtime fingerprint can still miss a metadata-preserving edit;
        // the pre/post comparison intentionally accepts that residual.
        guard before == after else { return "unstable:\(UUID().uuidString)" }
        return after
    }

    private func openRegularFile(
        repoRoot: String,
        relativePath: String
    ) throws -> (descriptor: Int32, metadata: Darwin.stat) {
        let components = relativePath.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw ArtifactByteReader.Error.fileNotFound
        }

        var directoryDescriptor = Darwin.open(
            repoRoot,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC
        )
        guard directoryDescriptor >= 0 else {
            throw ArtifactByteReader.Error.fileNotFound
        }
        for component in components.dropLast() {
            let nextDescriptor = component.withCString {
                Darwin.openat(
                    directoryDescriptor,
                    $0,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC
                )
            }
            guard nextDescriptor >= 0 else {
                Darwin.close(directoryDescriptor)
                throw ArtifactByteReader.Error.fileNotFound
            }
            Darwin.close(directoryDescriptor)
            directoryDescriptor = nextDescriptor
        }

        let descriptor = components[components.index(before: components.endIndex)]
            .withCString {
                Darwin.openat(
                    directoryDescriptor,
                    $0,
                    O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC
                )
            }
        Darwin.close(directoryDescriptor)
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
        return (descriptor, metadata)
    }

    private func fingerprint(metadata: Darwin.stat) -> String {
        let modifiedAtNanoseconds =
            Int64(metadata.st_mtimespec.tv_sec) * 1_000_000_000
            + Int64(metadata.st_mtimespec.tv_nsec)
        return "stat:\(max(Int64(metadata.st_size), 0)):\(modifiedAtNanoseconds)"
    }

    private func mimeType(path: String) -> String? {
        let fileExtension = URL(fileURLWithPath: path).pathExtension
        guard !fileExtension.isEmpty else { return nil }
        return UTType(filenameExtension: fileExtension)?.preferredMIMEType
    }
}
