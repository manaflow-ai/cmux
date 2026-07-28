import Darwin
import Foundation

/// Stable identity for the directory entry that cmux classified as owned.
///
/// Ownership registries use paths, but a path can name a different entry after
/// preparation yields. Cleanup is allowed only while this captured identity
/// still names the current entry.
nonisolated struct TextBoxPreparedLocalFileIdentity:
    Codable,
    Sendable,
    Equatable
{
    let device: dev_t
    let inode: ino_t
    let generation: UInt32
    let fileType: mode_t

    init(_ metadata: stat) {
        device = metadata.st_dev
        inode = metadata.st_ino
        generation = metadata.st_gen
        fileType = metadata.st_mode & mode_t(S_IFMT)
    }

    static func capture(at fileURL: URL) -> Self? {
        fileURL.standardizedFileURL.withUnsafeFileSystemRepresentation { path in
            guard let path else { return nil }
            var metadata = stat()
            guard Darwin.lstat(path, &metadata) == 0 else { return nil }
            return Self(metadata)
        }
    }

    func stillNamesEntry(at fileURL: URL) -> Bool {
        Self.capture(at: fileURL) == self
    }
}
