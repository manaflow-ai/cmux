import Darwin
import Foundation

/// A target content fingerprint used to discard unrelated or duplicate watcher events.
/// Status-change time is omitted because preview reads can update extended attributes.
struct FilePreviewFileState: Equatable {
    private let exists: Bool
    private let device: dev_t
    private let inode: ino_t
    private let size: off_t
    private let modificationTime: timespec

    static func capture(path: String) -> FilePreviewFileState {
        var attributes = stat()
        guard stat(path, &attributes) == 0 else {
            return FilePreviewFileState(
                exists: false,
                device: 0,
                inode: 0,
                size: 0,
                modificationTime: timespec()
            )
        }
        return FilePreviewFileState(
            exists: true,
            device: attributes.st_dev,
            inode: attributes.st_ino,
            size: attributes.st_size,
            modificationTime: attributes.st_mtimespec
        )
    }

    static func == (lhs: FilePreviewFileState, rhs: FilePreviewFileState) -> Bool {
        lhs.exists == rhs.exists
            && lhs.device == rhs.device
            && lhs.inode == rhs.inode
            && lhs.size == rhs.size
            && lhs.modificationTime.tv_sec == rhs.modificationTime.tv_sec
            && lhs.modificationTime.tv_nsec == rhs.modificationTime.tv_nsec
    }
}
