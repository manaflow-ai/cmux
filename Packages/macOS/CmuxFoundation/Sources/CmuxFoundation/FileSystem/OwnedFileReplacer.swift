public import Darwin
public import Foundation

/// Replaces a file's contents by renaming a private sibling over it.
///
/// `String.write(toFile:atomically:)` creates its temporary sibling with the
/// umask's default permissions and publishes it by rename, so narrowing the
/// mode afterwards leaves a window where another local user can open the new
/// file in a shared directory such as `/tmp` and keep reading through that
/// descriptor. This replacer creates the sibling exclusively with
/// ``creationMode`` before writing any byte, then renames it over the path.
/// The rename replaces a link at the path instead of following it.
///
/// ```swift
/// OwnedFileReplacer().replaceContents(ofPath: logPath, with: Data(text.utf8))
/// ```
public struct OwnedFileReplacer: Sendable, Equatable {
    /// The permission bits of the replacement file.
    public let creationMode: mode_t

    /// Creates a replacer.
    ///
    /// - Parameter creationMode: Permission bits for the replacement file.
    ///   Defaults to `0600` because debug logs can carry workspace details.
    public init(creationMode: mode_t = 0o600) {
        self.creationMode = creationMode
    }

    /// Replaces the file at `path` with `data`.
    ///
    /// - Parameters:
    ///   - path: The file to replace. It is created when missing.
    ///   - data: The new contents.
    /// - Returns: `true` when `path` now holds `data`; `false` when the
    ///   sibling could not be created or written, or the rename failed. No
    ///   sibling is left behind on failure.
    @discardableResult
    public func replaceContents(ofPath path: String, with data: Data) -> Bool {
        guard let sibling = stage(data, forPath: path) else { return false }
        guard rename(sibling, path) == 0 else {
            unlink(sibling)
            return false
        }
        return true
    }

    /// Writes `data` to a new private sibling of `path`.
    ///
    /// - Returns: The sibling's path, or `nil` after removing a partial one.
    func stage(_ data: Data, forPath path: String) -> String? {
        let url = URL(fileURLWithPath: path)
        let sibling = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString)", isDirectory: false)
            .path
        let fd = open(sibling, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, creationMode)
        guard fd >= 0 else { return nil }
        // The umask can only clear bits from the creation mode; set it exactly.
        let written = fchmod(fd, creationMode) == 0 && Self.writeAll(data, to: fd)
        let closed = close(fd) == 0
        guard written, closed else {
            unlink(sibling)
            return nil
        }
        return sibling
    }

    private static func writeAll(_ data: Data, to fd: Int32) -> Bool {
        data.withUnsafeBytes { buffer in
            guard var cursor = buffer.baseAddress else { return true }
            var remaining = buffer.count
            while remaining > 0 {
                let count = write(fd, cursor, remaining)
                if count < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                cursor += count
                remaining -= count
            }
            return true
        }
    }
}
