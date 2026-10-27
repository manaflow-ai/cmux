#if os(Linux)
import CmuxNextCompat
import Foundation
import Glibc

/// Glibc's module has no `fts.h`, so the Linux walk reads each folder with `readdir(3)`, takes
/// directory-ness from `d_type` (a `stat` only when the file system leaves it unknown), and opens
/// each child folder relative to its parent, as base::FileEnumerator does on POSIX
/// (base/files/file_enumerator_posix.cc). A child folder that cannot be read is skipped, as fts
/// reports it (FTS_DNR) and walks on.
extension FolderNameIndex {
    /// Walks the tree under `rootPath`, depth first, and hands `visit` each item's full path and
    /// whether it is a directory; true when `visit` ended the walk.
    /// Each file system call is a checked blocking call (CmuxNextCompat/Threading).
    static func walk(_ rootPath: String, root: URL, _ visit: (String, Bool) -> WalkStep) throws -> Bool {
        // SAFETY: opendir reads the NUL-terminated copy of the path made for the call.
        guard let top = unsafe blockingCall(.fileIO, { unsafe opendir(rootPath) }) else {
            throw FileBrowserError.unreadable(root, errno)
        }
        return unsafe walk(top, path: rootPath == "/" ? "" : rootPath, visit)
    }

    /// Walks one open folder stream, which it closes; true when `visit` ended the walk.
    private static func walk(_ directory: OpaquePointer, path: String, _ visit: (String, Bool) -> WalkStep) -> Bool {
        // SAFETY: `directory` is an open stream this call owns, closed once here.
        defer { unsafe closedir(directory) }
        // SAFETY: `directory` is open until the defer above.
        let fd = unsafe dirfd(directory)
        // SAFETY: each dirent readdir returns lives until the next readdir or closedir on `directory`; its name and
        // type are copied out before the next call. fstatat and openat read the NUL-terminated copy of the name made
        // for each call, and fstatat writes one struct stat into `info`, a local.
        while let item = unsafe blockingCall(.fileIO, { unsafe readdir(directory) }) {
            let name = unsafe withUnsafeBytes(of: item.pointee.d_name) { bytes in
                unsafe String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
            }
            if name == "." || name == ".." { continue }
            var isDirectory = unsafe item.pointee.d_type == UInt8(DT_DIR)
            if unsafe item.pointee.d_type == UInt8(DT_UNKNOWN) {
                var info = stat()
                let found = blockingCall(.fsMetadata, { unsafe fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) })
                isDirectory = found == 0 && info.st_mode & S_IFMT == S_IFDIR
            }
            let full = path + "/" + name
            switch visit(full, isDirectory) {
            case .stop: return true
            case .skipChildren: continue
            case .next: break
            }
            guard isDirectory else { continue }
            let child = blockingCall(.fileIO, { unsafe openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) })
            guard child >= 0 else { continue }
            // SAFETY: fdopendir takes `child`, an open descriptor; on failure it is still ours to close.
            guard let stream = unsafe fdopendir(child) else {
                close(child)
                continue
            }
            if unsafe walk(stream, path: full, visit) { return true }
        }
        return false
    }
}
#endif
