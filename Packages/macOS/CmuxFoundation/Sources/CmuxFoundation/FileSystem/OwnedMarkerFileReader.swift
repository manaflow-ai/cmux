public import Darwin
public import Foundation

/// Reads a small text marker file only when it is a regular file owned by the
/// expected user.
///
/// Scripts leave markers such as `/tmp/cmux-last-debug-log-path` in the shared
/// `/tmp` directory. Another local user could create that path first and point
/// cmux at a file of their choosing, so a marker is trusted only when this user
/// owns it and it is not a symbolic link.
///
/// ```swift
/// let logPath = OwnedMarkerFileReader().trimmedContents(atPath: "/tmp/cmux-last-debug-log-path")
/// ```
public struct OwnedMarkerFileReader: Sendable, Equatable {
    /// The user ID that must own the marker.
    public let expectedOwnerID: uid_t
    /// The largest marker this reader accepts, in bytes.
    public let maximumBytes: Int

    /// Creates a reader.
    ///
    /// - Parameters:
    ///   - expectedOwnerID: The user ID that must own the marker. Defaults to
    ///     this process's effective user ID.
    ///   - maximumBytes: The largest marker accepted. Defaults to 4096 bytes,
    ///     above `PATH_MAX`.
    public init(expectedOwnerID: uid_t = geteuid(), maximumBytes: Int = 4096) {
        self.expectedOwnerID = expectedOwnerID
        self.maximumBytes = maximumBytes
    }

    /// The marker's UTF-8 contents with surrounding whitespace trimmed.
    ///
    /// - Parameter path: The marker file.
    /// - Returns: The trimmed contents, or `nil` when the marker is missing,
    ///   empty, a symbolic link, not a regular file, owned by another user,
    ///   larger than ``maximumBytes``, or not UTF-8.
    public func trimmedContents(atPath path: String) -> String? {
        // O_NONBLOCK keeps a planted FIFO from blocking the open.
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var status = stat()
        guard fstat(fd, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              status.st_uid == expectedOwnerID,
              status.st_nlink == 1,
              status.st_size <= off_t(maximumBytes),
              let data = try? handle.read(upToCount: maximumBytes),
              let contents = String(data: data, encoding: .utf8) else {
            return nil
        }
        let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
