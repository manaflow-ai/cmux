#if canImport(Darwin)
import Darwin
import Foundation

extension FolderNameIndex {
    /// Walks the tree under `rootPath` with `fts(3)`, depth first, and hands `visit` each item's
    /// full path and whether it is a directory; true when `visit` ended the walk.
    static func walk(_ rootPath: String, root: URL, _ visit: (String, Bool) -> WalkStep) throws -> Bool {
        // SAFETY: fts_open reads `argv`, a NULL-terminated array of one strdup'd copy of the root path; both live
        // until the walk ends (the defers). Each FTSENT fts_read returns stays valid until the next fts_read or
        // fts_close on the stream, and the loop reads its fields (fts_info, fts_level, the NUL-terminated fts_path)
        // or hands it back to fts_set before asking for the next one; no FTSENT pointer outlives its turn.
        try unsafe rootPath.withCString { cPath -> Bool in
            let argv = unsafe UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: 2)
            defer { unsafe argv.deallocate() }
            let copy = unsafe strdup(cPath)
            defer { unsafe free(copy) }
            unsafe argv[0] = copy
            unsafe argv[1] = nil
            // FTS_NOSTAT: directory-ness comes from d_type, so no stat per file.
            guard let stream = unsafe fts_open(argv, FTS_PHYSICAL | FTS_NOCHDIR | FTS_NOSTAT, nil) else {
                throw FileBrowserError.unreadable(root, errno)
            }
            defer { unsafe fts_close(stream) }
            while let entry = unsafe fts_read(stream) {
                let info = unsafe Int32(entry.pointee.fts_info)
                if unsafe entry.pointee.fts_level == 0 { continue }
                if info == FTS_DP { continue }
                let full = unsafe String(cString: entry.pointee.fts_path)
                let isDirectory = info == FTS_D || info == FTS_DC || info == FTS_DOT
                switch visit(full, isDirectory) {
                case .next: break
                case .skipChildren: unsafe fts_set(stream, entry, FTS_SKIP)
                case .stop: return true
                }
            }
            return false
        }
    }
}
#endif
