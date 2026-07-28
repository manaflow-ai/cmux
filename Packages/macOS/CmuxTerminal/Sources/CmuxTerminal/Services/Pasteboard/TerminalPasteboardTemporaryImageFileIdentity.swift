internal import Darwin
internal import Foundation

/// The filesystem identity of an owned temporary image directory entry.
///
/// Device and inode come from `lstat(2)`, so replacing the path with another
/// file or a symbolic link changes the identity and prevents cleanup from
/// deleting the replacement.
struct TerminalPasteboardTemporaryImageFileIdentity: Equatable, Sendable {
    let device: UInt64
    let inode: UInt64

    init?(capturing fileURL: URL) {
        guard fileURL.isFileURL else { return nil }
        var metadata = stat()
        guard Darwin.lstat(fileURL.path, &metadata) == 0 else { return nil }
        self.device = UInt64(metadata.st_dev)
        self.inode = UInt64(metadata.st_ino)
    }

    func stillNamesEntry(at fileURL: URL) -> Bool {
        Self(capturing: fileURL) == self
    }

    @discardableResult
    func unlinkIfStillNamesEntry(
        at fileURL: URL,
        afterIdentityCheck: () -> Void = {}
    ) -> Bool {
        guard stillNamesEntry(at: fileURL) else { return false }
        afterIdentityCheck()
        return Darwin.unlink(fileURL.path) == 0
    }
}
