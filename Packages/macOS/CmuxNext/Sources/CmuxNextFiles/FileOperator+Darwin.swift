#if canImport(Darwin)
import Darwin
import Foundation

extension FileOperator {
    /// rename(2), which the instance method of that name hides.
    static func systemRename(_ source: String, _ target: String) -> Int32 {
        // SAFETY: rename reads the NUL-terminated copies of both paths made for the call.
        unsafe Darwin.rename(source, target)
    }

    /// Moves `url` to the Trash, which names it itself (`namer` names items in the Linux trash); the item's URL
    /// there.
    static func systemTrash(_ url: URL, namer: FileNamer) throws -> URL {
        var result: NSURL?
        // SAFETY: `result` is a local that outlives the call; Foundation stores at most one autoreleased NSURL
        // through the pointer and keeps no reference to it.
        try unsafe FileManager.default.trashItem(at: url, resultingItemURL: &result)
        return (result as URL?) ?? url
    }

    /// The Trash keeps no record beside the item: nothing to remove after Put Back.
    static func forgetTrashed(_ trashed: URL) {}

    /// Copies `source` to `target` (recursively, with metadata, cloning on
    /// APFS). `progress` gets the bytes copied of the current file and
    /// returns false to stop; it is called only during this call.
    static func copy(_ source: URL, to target: URL, progress: (Int64) -> Bool) throws {
        try withoutActuallyEscaping(progress) { progress in
            let context = CopyProgressContext(progress: progress)
            // SAFETY: `state` is this call's own copyfile state, freed once on return, and copyfile runs the callback
            // only inside the copyfile call below, on this thread. The callback's context is `context`, retained here
            // and released on return, so it is live whenever the callback runs. copyfile_state_set takes the callback
            // as a raw pointer and keeps the C function itself (copyfile.c: `s->statuscb = thing`), a global that
            // lives for the process; copyfile reads the NUL-terminated copies of both paths made for the call.
            let state = unsafe copyfile_state_alloc()
            defer { unsafe copyfile_state_free(state) }
            let unmanaged = unsafe Unmanaged.passRetained(context)
            defer { unsafe unmanaged.release() }
            unsafe copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CTX), unmanaged.toOpaque())
            unsafe copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CB), unsafeBitCast(copyProgressCallback, to: UnsafeRawPointer.self))
            let flags = copyfile_flags_t(COPYFILE_ALL | COPYFILE_RECURSIVE | COPYFILE_CLONE | COPYFILE_EXCL | COPYFILE_NOFOLLOW_SRC)
            if unsafe copyfile(source.path, target.path, state, flags) != 0 {
                if context.stopped { throw FileBrowserError.cancelled }
                throw FileBrowserError.posix(errno)
            }
        }
    }
}

/// Carries the progress closure into `copyfile`'s C callback, which runs
/// synchronously on the copying thread.
// Only touched by the one thread inside copyfile(3); never shared.
final class CopyProgressContext: @unchecked Sendable { // crash-allow: one copy's context; only the copyfile(3) thread touches it, through the callback's ctx pointer
    let progress: (Int64) -> Bool
    var stopped = false
    init(progress: @escaping (Int64) -> Bool) { self.progress = progress }
}

private let copyProgressCallback: copyfile_callback_t = { what, stage, state, _, _, ctx in
    // SAFETY: `ctx` is the CopyProgressContext FileOperator.copy retained for the copyfile call this callback runs
    // inside (see there), so it is live; `state` is that call's copyfile state, and copyfile_state_get writes one
    // off_t into `copied`, a local live for the call.
    guard let ctx = unsafe ctx else { return COPYFILE_CONTINUE }
    let context = unsafe Unmanaged<CopyProgressContext>.fromOpaque(ctx).takeUnretainedValue()
    if what == COPYFILE_COPY_DATA, stage == COPYFILE_PROGRESS {
        var copied: off_t = 0
        unsafe copyfile_state_get(state, UInt32(COPYFILE_STATE_COPIED), &copied)
        if !context.progress(Int64(copied)) {
            context.stopped = true
            return COPYFILE_QUIT
        }
    }
    return COPYFILE_CONTINUE
}
#endif
