import Foundation

// ``HistoryFileWatch`` watches one history database for ``ImportHistorySync``: kqueue sources on Apple platforms
// (HistoryFileWatch+Kqueue.swift), one inotify watch on its folder on Linux (HistoryFileWatch+Inotify.swift).
// Both have `init(file:scope:onChange:)`, `file` and `cancel()`, and call `onChange` when the database, its
// `-wal` or its `-journal` changes; ``stamp(_:)`` then says whether there is anything to read.
extension HistoryFileWatch {
    /// Size and change time (seconds, nanoseconds) of the database, its `-wal` and `-journal`: equal stamps,
    /// nothing to read. The fields are kept apart: any time a file system holds is a stamp, with no product
    /// that a far-future change time could overflow.
    static func stamp(_ file: URL) -> [Int64] {
        [file.path, file.path + "-wal", file.path + "-journal"].flatMap { path -> [Int64] in
            var info = stat()
            // SAFETY: the path is a NUL-terminated copy Swift keeps alive for the call; stat writes one
            // `stat` into the local `info`, which outlives it.
            guard unsafe stat(path, &info) == 0 else { return [-1, -1, -1] }
            #if canImport(Darwin)
            let changed = info.st_mtimespec
            #else
            let changed = info.st_mtim
            #endif
            return [Int64(truncatingIfNeeded: info.st_size), Int64(truncatingIfNeeded: changed.tv_sec),
                    Int64(truncatingIfNeeded: changed.tv_nsec)]
        }
    }
}
