import Darwin
import Foundation

/// Identity and mutation state for one regular-file generation.
struct AgentConversationStorageGeneration: Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
    let mode: UInt32
    let owner: UInt32
    let size: Int64
    let birthSeconds: Int64
    let birthNanoseconds: Int64
    let modificationSeconds: Int64
    let modificationNanoseconds: Int64
    let statusChangeSeconds: Int64?
    let statusChangeNanoseconds: Int64?

    static func capture(atPath path: String) -> Self? {
        captureStorage(atPath: path)?.generation
    }

    /// Resolves a configured symlink once, then captures the generation of its
    /// regular-file target so later readers can use the same canonical path.
    static func captureStorage(
        atPath path: String,
        includeStatusChangeTime: Bool = true
    ) -> (path: String, generation: Self)? {
        var resolvedPathBuffer = [CChar](
            repeating: 0,
            count: Int(PATH_MAX)
        )
        let didResolve = path.withCString { sourcePath in
            resolvedPathBuffer.withUnsafeMutableBufferPointer { destination in
                Darwin.realpath(sourcePath, destination.baseAddress) != nil
            }
        }
        guard didResolve else { return nil }
        let resolvedPath = String(cString: resolvedPathBuffer)
        let descriptor = Darwin.open(
            resolvedPath,
            O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else { return nil }
        defer { _ = Darwin.close(descriptor) }

        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG else {
            return nil
        }
        return (
            resolvedPath,
            Self(
                metadata: metadata,
                includeStatusChangeTime: includeStatusChangeTime
            )
        )
    }

    func matches(_ metadata: stat) -> Bool {
        self == Self(
            metadata: metadata,
            includeStatusChangeTime: statusChangeSeconds != nil
        )
    }

    func isCurrent(atPath path: String) -> Bool {
        Self.captureStorage(
            atPath: path,
            includeStatusChangeTime: statusChangeSeconds != nil
        )?.generation == self
    }

    static func openRegularFile(
        at url: URL,
        matching expected: Self? = nil
    ) -> (handle: FileHandle, endOffset: UInt64)? {
        let descriptor = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(
                path,
                O_RDONLY | O_NONBLOCK | O_CLOEXEC
            )
        }
        guard descriptor >= 0 else { return nil }

        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_size >= 0,
              expected.map({ $0.matches(metadata) }) != false else {
            _ = Darwin.close(descriptor)
            return nil
        }
        return (
            FileHandle(fileDescriptor: descriptor, closeOnDealloc: true),
            UInt64(metadata.st_size)
        )
    }

    static func captureOptionalRegularFile(
        atPath path: String,
        includeStatusChangeTime: Bool = true
    ) -> (isValid: Bool, generation: Self?) {
        let descriptor = Darwin.open(
            path,
            O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            return errno == ENOENT ? (true, nil) : (false, nil)
        }
        defer { _ = Darwin.close(descriptor) }

        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_size >= 0 else {
            return (false, nil)
        }
        return (
            true,
            Self(
                metadata: metadata,
                includeStatusChangeTime: includeStatusChangeTime
            )
        )
    }

    private init(metadata: stat, includeStatusChangeTime: Bool = true) {
        device = UInt64(metadata.st_dev)
        inode = UInt64(metadata.st_ino)
        mode = UInt32(metadata.st_mode)
        owner = UInt32(metadata.st_uid)
        size = Int64(metadata.st_size)
        birthSeconds = Int64(metadata.st_birthtimespec.tv_sec)
        birthNanoseconds = Int64(metadata.st_birthtimespec.tv_nsec)
        modificationSeconds = Int64(metadata.st_mtimespec.tv_sec)
        modificationNanoseconds = Int64(metadata.st_mtimespec.tv_nsec)
        statusChangeSeconds = includeStatusChangeTime
            ? Int64(metadata.st_ctimespec.tv_sec)
            : nil
        statusChangeNanoseconds = includeStatusChangeTime
            ? Int64(metadata.st_ctimespec.tv_nsec)
            : nil
    }
}
