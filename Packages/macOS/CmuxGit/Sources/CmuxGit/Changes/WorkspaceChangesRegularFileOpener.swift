internal import CmuxAgentChat
internal import Darwin

/// Opens repository-relative regular files without following any path-component symlink.
struct WorkspaceChangesRegularFileOpener: Sendable {
    func open(
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
}
