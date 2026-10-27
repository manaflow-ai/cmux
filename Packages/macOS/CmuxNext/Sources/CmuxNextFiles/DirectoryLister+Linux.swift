#if os(Linux)
import CmuxNextCompat
public import Foundation
import Glibc

/// The Linux listing: `readdir(3)` gives the names, then one `fstatat(2)` per item relative to the
/// open folder (no path walk per item), as base::FileEnumerator does on POSIX
/// (base/files/file_enumerator_posix.cc). Linux has no `UF_HIDDEN` flag, so a dot name alone is
/// hidden, and `stat` keeps no creation time, so ``FileEntry/created`` is the modification time.
/// Each file system call is a checked blocking call (CmuxNextCompat/Threading).
extension DirectoryLister {
    /// The synchronous listing (also used by benchmarks).
    public static func listSync(_ folder: URL) throws -> [FileEntry] {
        // SAFETY: opendir reads the NUL-terminated copy of the path made for the call.
        guard let directory = unsafe blockingCall(.fileIO, { unsafe opendir(folder.path) }) else {
            throw FileBrowserError.unreadable(folder, errno)
        }
        // SAFETY: `directory` is the stream opendir returned above, closed once here.
        defer { unsafe closedir(directory) }
        // SAFETY: `directory` is open until the defer above.
        let fd = unsafe dirfd(directory)
        var entries: [FileEntry] = []
        errno = 0
        // SAFETY: each dirent readdir returns lives until the next readdir or closedir on `directory`; its name is
        // copied out before the next call, and fstatat reads that copy and writes one struct stat into `info`.
        while let item = unsafe blockingCall(.fileIO, { unsafe readdir(directory) }) {
            let name = unsafe withUnsafeBytes(of: item.pointee.d_name) { bytes in
                unsafe String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
            }
            var info = stat()
            // An item removed since readdir named it is skipped.
            if name != ".", name != "..",
               blockingCall(.fsMetadata, { unsafe fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) }) == 0 {
                entries.append(entry(name: name, in: folder, info: info))
            }
            errno = 0
        }
        if errno != 0 { throw FileBrowserError.unreadable(folder, errno) }
        return entries
    }

    /// One item through `lstat`, or nil when it is gone.
    public static func entrySync(at url: URL) -> FileEntry? {
        var info = stat()
        // SAFETY: lstat reads the NUL-terminated copy of the path made for the call and writes one struct stat into
        // `info`, a local live for the call.
        guard unsafe blockingLstat(url.path, &info) == 0 else { return nil }
        return entry(name: url.lastPathComponent, in: url.deletingLastPathComponent(), info: info)
    }

    private static func entry(name: String, in folder: URL, info: stat) -> FileEntry {
        let kind: FileKind
        switch info.st_mode & S_IFMT {
        case S_IFDIR: kind = isPackage(name) ? .package : .folder
        case S_IFREG: kind = .file
        case S_IFLNK: kind = .symlink
        default: kind = .other
        }
        let modified = date(info.st_mtim)
        return FileEntry(name: name, in: folder, kind: kind, size: kind == .file ? Int64(info.st_size) : 0,
                         modified: modified, created: modified, isHidden: name.hasPrefix("."))
    }
}
#endif
