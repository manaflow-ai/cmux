import Darwin

/// The device and inode of a file system entry: the same entry while both match, whatever its
/// name. A socket file put back at a path, or another app's file renamed over it, has a new one.
struct FileIdentity: Equatable, Sendable {
    var device: dev_t
    var inode: ino_t

    init(_ info: stat) {
        device = info.st_dev
        inode = info.st_ino
    }

    /// The identity of what is at `path` (not following a link), nil for nothing there.
    static func at(_ path: String) -> FileIdentity? {
        var info = stat()
        return lstat(path, &info) == 0 ? FileIdentity(info) : nil
    }
}
