import Darwin
import Foundation

private enum LiveAgentContextHandoffFileReadError: Error {
    case openFailed
    case metadataFailed
    case readFailed
}

/// Live local-filesystem implementation used by the handoff verifier.
actor LiveAgentContextHandoffFileSystem: AgentContextHandoffFileSystem {
    /// Creates the live descriptor-backed adapter.
    init() {}

    func readSnapshot(
        at path: URL,
        maximumBytes: Int
    ) async throws -> AgentContextHandoffFileSnapshot? {
        // Open and validate one descriptor rather than checking the pathname
        // and reopening it later. `O_NOFOLLOW` closes the symlink race, while
        // `O_NONBLOCK` ensures a FIFO/device cannot strand the verifier actor
        // before `fstat` rejects its non-regular type.
        let descriptor = Darwin.open(
            path.path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
        )
        guard descriptor >= 0 else {
            if Darwin.errno == ENOENT || Darwin.errno == ENOTDIR {
                return nil
            }
            throw LiveAgentContextHandoffFileReadError.openFailed
        }

        var fileInfo = stat()
        guard fstat(descriptor, &fileInfo) == 0 else {
            Darwin.close(descriptor)
            throw LiveAgentContextHandoffFileReadError.metadataFailed
        }

        let metadata = AgentContextHandoffFileMetadata(
            isRegularFile: (fileInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
            modificationDate: Self.modificationDate(from: fileInfo),
            size: Int(exactly: fileInfo.st_size) ?? -1,
            deviceID: UInt64(fileInfo.st_dev),
            fileID: UInt64(fileInfo.st_ino)
        )
        guard metadata.isRegularFile else {
            Darwin.close(descriptor)
            return AgentContextHandoffFileSnapshot(metadata: metadata, data: Data())
        }
        guard metadata.size > 0,
              metadata.size <= max(0, maximumBytes) else {
            Darwin.close(descriptor)
            return AgentContextHandoffFileSnapshot(metadata: metadata, data: Data())
        }

        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        let readLimit = maximumBytes >= Int.max
            ? Int.max
            : max(0, maximumBytes) + 1
        do {
            let data = try handle.read(upToCount: readLimit) ?? Data()
            var postReadInfo = stat()
            guard fstat(descriptor, &postReadInfo) == 0,
                  Self.metadataIsStable(before: fileInfo, after: postReadInfo) else {
                throw LiveAgentContextHandoffFileReadError.metadataFailed
            }
            return AgentContextHandoffFileSnapshot(metadata: metadata, data: data)
        } catch {
            if let error = error as? LiveAgentContextHandoffFileReadError {
                throw error
            }
            throw LiveAgentContextHandoffFileReadError.readFailed
        }
    }

    private static func modificationDate(from fileInfo: stat) -> Date? {
        let seconds = Double(fileInfo.st_mtimespec.tv_sec)
        let nanoseconds = Double(fileInfo.st_mtimespec.tv_nsec) / 1_000_000_000
        return Date(timeIntervalSince1970: seconds + nanoseconds)
    }

    private static func metadataIsStable(before: stat, after: stat) -> Bool {
        before.st_dev == after.st_dev
            && before.st_ino == after.st_ino
            && before.st_size == after.st_size
            && before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec
            && before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec
            && before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec
            && before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec
    }
}
