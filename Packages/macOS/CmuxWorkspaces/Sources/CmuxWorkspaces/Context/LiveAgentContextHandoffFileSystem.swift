import Darwin
import Foundation

private enum LiveAgentContextHandoffFileReadError: Error {
    case openFailed
    case metadataFailed
    case notRegularFile
    case readFailed
}

/// Live local-filesystem implementation used by the handoff verifier.
actor LiveAgentContextHandoffFileSystem: AgentContextHandoffFileSystem {
    private let fileManager: FileManager

    /// Creates the live adapter with its filesystem dependency.
    /// - Parameter fileManager: Filesystem implementation used for metadata.
    init(fileManager: FileManager) {
        self.fileManager = fileManager
    }

    func metadata(for path: URL) async throws -> AgentContextHandoffFileMetadata? {
        guard fileManager.fileExists(atPath: path.path) else { return nil }
        let attributes = try fileManager.attributesOfItem(atPath: path.path)
        return AgentContextHandoffFileMetadata(
            isRegularFile: (attributes[.type] as? FileAttributeType) == .typeRegular,
            modificationDate: attributes[.modificationDate] as? Date,
            size: (attributes[.size] as? NSNumber)?.intValue ?? -1
        )
    }

    func readData(at path: URL, maximumBytes: Int) async throws -> Data {
        // Open and validate one descriptor rather than checking the pathname
        // and reopening it later. `O_NOFOLLOW` closes the symlink race, while
        // `O_NONBLOCK` ensures a FIFO/device cannot strand the verifier actor
        // before `fstat` rejects its non-regular type.
        let descriptor = Darwin.open(
            path.path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
        )
        guard descriptor >= 0 else {
            throw LiveAgentContextHandoffFileReadError.openFailed
        }

        var fileInfo = stat()
        guard fstat(descriptor, &fileInfo) == 0 else {
            Darwin.close(descriptor)
            throw LiveAgentContextHandoffFileReadError.metadataFailed
        }
        guard (fileInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
            Darwin.close(descriptor)
            throw LiveAgentContextHandoffFileReadError.notRegularFile
        }

        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        let readLimit = maximumBytes >= Int.max
            ? Int.max
            : max(0, maximumBytes) + 1
        do {
            return try handle.read(upToCount: readLimit) ?? Data()
        } catch {
            throw LiveAgentContextHandoffFileReadError.readFailed
        }
    }
}
