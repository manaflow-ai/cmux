import CmuxNextCompat
public import CmuxNextWakeups
public import Foundation

/// ``FileOperating`` on the real file system, on the app's files lanes (never the main actor or the
/// cooperative pool: Chrome's `MayBlock` trait, base/task/task_traits.h). A short call (rename, new folder)
/// is one ``BlockingLane/files`` item; a call whose length grows with its input (a copy, a trash, a delete,
/// a transfer) runs on ``BlockingLane/bulkFiles``, so it never holds the serial files slot.
///
/// Copies go through `copyfile(3)` with `COPYFILE_CLONE`, so an APFS copy of
/// any size is a metadata-only clone, and report bytes as they go.
public struct FileOperator: FileOperating {
    let namer: FileNamer
    /// The app's blocking-work lanes (the composition root's one ``BackgroundWork``).
    let work: BackgroundWork

    /// Makes an operator. `namer` makes "copy" and numbered names; `work` runs the file calls.
    public init(namer: FileNamer = FileNamer(), work: BackgroundWork) {
        self.namer = namer
        self.work = work
    }

    public func rename(_ url: URL, to name: String) async throws -> URL {
        guard namer.isValid(name) else { throw FileBrowserError.invalidName(name) }
        let target = url.deletingLastPathComponent().appendingPathComponent(name)
        if target.path == url.path { return url }
        // A case-only rename on a case-insensitive volume is the same item.
        let caseOnly = target.path.lowercased() == url.path.lowercased()
        return try await work.run(.userBlocking, mayBlock: .files) {
            if !caseOnly, FileManager.default.fileExists(atPath: target.path) { throw FileBrowserError.exists(target) }
            guard Darwin.rename(url.path, target.path) == 0 else { throw FileBrowserError.failed(String(cString: strerror(errno))) }
            return target
        }
    }

    public func newFolder(in folder: URL, named name: String) async throws -> URL {
        guard namer.isValid(name) else { throw FileBrowserError.invalidName(name) }
        let namer = namer
        return try await work.run(.userBlocking, mayBlock: .files) {
            let free = namer.freeName(for: name, style: .number, taken: Self.names(in: folder))
            let target = folder.appendingPathComponent(free, isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
            } catch {
                throw FileBrowserError.failed(error.localizedDescription)
            }
            return target
        }
    }

    public func newFile(in folder: URL, named name: String, contents: Data) async throws -> URL {
        guard namer.isValid(name) else { throw FileBrowserError.invalidName(name) }
        let namer = namer
        return try await work.run(.userBlocking, mayBlock: .files) {
            let target = folder.appendingPathComponent(namer.freeName(for: name, style: .number, taken: Self.names(in: folder)))
            do {
                try contents.blockingWrite(to: target, options: .withoutOverwriting)
            } catch {
                throw FileBrowserError.failed(error.localizedDescription)
            }
            return target
        }
    }

    public func duplicate(_ urls: [URL]) async throws -> [URL] {
        var made: [URL] = []
        let namer = namer
        for url in urls {
            try Task.checkCancellation()
            // A copy of a folder on a volume that cannot clone takes as long as its bytes: the bulk lane.
            made.append(try await work.run(.userBlocking, mayBlock: .bulkFiles) {
                let folder = url.deletingLastPathComponent()
                let free = namer.freeName(for: url.lastPathComponent, style: .copy, taken: Self.names(in: folder))
                let target = folder.appendingPathComponent(free)
                try Self.copy(url, to: target, progress: { _ in true })
                return target
            })
        }
        return made
    }

    public func trash(_ urls: [URL]) async throws -> [TrashedItem] {
        // A trash of many items (or across volumes, which copies) is long: the bulk lane.
        try await work.run(.userBlocking, mayBlock: .bulkFiles) {
            var done: [TrashedItem] = []
            for url in urls {
                var result: NSURL?
                do {
                    try FileManager.default.trashItem(at: url, resultingItemURL: &result)
                } catch {
                    throw FileBrowserError.failed(error.localizedDescription)
                }
                done.append(TrashedItem(original: url, trashed: (result as URL?) ?? url))
            }
            return done
        }
    }

    public func putBack(_ items: [TrashedItem]) async throws -> [URL] {
        let namer = namer
        return try await work.run(.userBlocking, mayBlock: .files) {
            var placed: [URL] = []
            for item in items {
                let folder = item.original.deletingLastPathComponent()
                let free = namer.freeName(for: item.original.lastPathComponent, style: .number, taken: Self.names(in: folder))
                let target = folder.appendingPathComponent(free)
                do {
                    try FileManager.default.moveItem(at: item.trashed, to: target)
                } catch {
                    throw FileBrowserError.failed(error.localizedDescription)
                }
                placed.append(target)
            }
            return placed
        }
    }

    public func move(_ pairs: [(from: URL, to: URL)]) async throws {
        let moves = pairs.map { Move(from: $0.from, to: $0.to) }
        try await work.run(.userBlocking, mayBlock: .files) { try Self.move(moves) }
    }

    /// One pair of ``move(_:)``: a tuple is not Sendable, so the lane gets these.
    struct Move: Sendable {
        let from: URL
        let to: URL
    }

    /// ``move(_:)`` on the lane thread.
    static func move(_ pairs: [Move]) throws {
        // A destination that another pair is leaving (a swap or a shift of
        // numbered names) is taken until that pair moves: go through free
        // temporary names first, then to the real ones.
        let leaving = Set(pairs.map(\.from.path))
        if pairs.contains(where: { leaving.contains($0.to.path) && $0.to.path != $0.from.path }) {
            let parked = pairs.map { pair in
                Move(from: pair.from, to: pair.from.deletingLastPathComponent()
                    .appendingPathComponent(".cmux-move-\(UUID().uuidString)"))
            }
            try move(parked)
            try move(zip(parked, pairs).map { Move(from: $0.to, to: $1.to) })
            return
        }
        for pair in pairs {
            if FileManager.default.fileExists(atPath: pair.to.path) { throw FileBrowserError.exists(pair.to) }
            do {
                try FileManager.default.moveItem(at: pair.from, to: pair.to)
            } catch {
                throw FileBrowserError.failed(error.localizedDescription)
            }
        }
    }
    public func transfer(_ sources: [URL], to folder: URL, mode: TransferMode,
                         resolve: @escaping @Sendable (FileConflict) async -> ConflictAnswer)
        -> AsyncThrowingStream<TransferEvent, any Error> {
        let job = FileTransferJob(sources: sources, folder: folder, mode: mode, namer: namer, resolve: resolve, work: work)
        // Progress events are snapshots and `.finished` is always the last one, so dropping the
        // oldest when the reader lags loses nothing it needs.
        return AsyncThrowingStream(bufferingPolicy: .bufferingNewest(16)) { continuation in
            // The job only awaits lane items and the conflict answers; its file calls run on the bulk lane.
            // task-owner: the stream's termination cancels it; a refused lane item ends it with a cancel.
            let task = Task(priority: .userInitiated) {
                do {
                    try await job.run { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error is CancellationError ? FileBrowserError.cancelled : error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The names in `folder` (for free-name checks).
    static func names(in folder: URL) -> Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
    }

    /// Copies `source` to `target` (recursively, with metadata, cloning on
    /// APFS). `progress` gets the bytes copied of the current file and
    /// returns false to stop; it is called only during this call.
    static func copy(_ source: URL, to target: URL, progress: (Int64) -> Bool) throws {
        try withoutActuallyEscaping(progress) { progress in
            let context = CopyProgressContext(progress: progress)
            let state = copyfile_state_alloc()
            defer { copyfile_state_free(state) }
            let unmanaged = Unmanaged.passRetained(context)
            defer { unmanaged.release() }
            copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CTX), unmanaged.toOpaque())
            // copyfile keeps the function pointer itself (copyfile.c: `s->statuscb = thing`).
            copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CB), unsafeBitCast(copyProgressCallback, to: UnsafeRawPointer.self))
            let flags = copyfile_flags_t(COPYFILE_ALL | COPYFILE_RECURSIVE | COPYFILE_CLONE | COPYFILE_EXCL | COPYFILE_NOFOLLOW_SRC)
            if copyfile(source.path, target.path, state, flags) != 0 {
                if context.stopped { throw FileBrowserError.cancelled }
                throw FileBrowserError.failed(String(cString: strerror(errno)))
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
    guard let ctx else { return COPYFILE_CONTINUE }
    let context = Unmanaged<CopyProgressContext>.fromOpaque(ctx).takeUnretainedValue()
    if what == COPYFILE_COPY_DATA, stage == COPYFILE_PROGRESS {
        var copied: off_t = 0
        copyfile_state_get(state, UInt32(COPYFILE_STATE_COPIED), &copied)
        if !context.progress(Int64(copied)) {
            context.stopped = true
            return COPYFILE_QUIT
        }
    }
    return COPYFILE_CONTINUE
}
