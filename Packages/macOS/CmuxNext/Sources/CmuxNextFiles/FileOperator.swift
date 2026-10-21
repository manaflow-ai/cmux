public import Foundation

/// ``FileOperating`` on the real file system, off the main actor.
///
/// Copies go through `copyfile(3)` with `COPYFILE_CLONE`, so an APFS copy of
/// any size is a metadata-only clone, and report bytes as they go.
public struct FileOperator: FileOperating {
    let namer: FileNamer

    /// Makes an operator. `namer` makes "copy" and numbered names.
    public init(namer: FileNamer = FileNamer()) { self.namer = namer }

    @concurrent
    public func rename(_ url: URL, to name: String) async throws -> URL {
        guard namer.isValid(name) else { throw FileBrowserError.invalidName(name) }
        let target = url.deletingLastPathComponent().appendingPathComponent(name)
        if target.path == url.path { return url }
        // A case-only rename on a case-insensitive volume is the same item.
        let caseOnly = target.path.lowercased() == url.path.lowercased()
        if !caseOnly, FileManager.default.fileExists(atPath: target.path) { throw FileBrowserError.exists(target) }
        guard Darwin.rename(url.path, target.path) == 0 else { throw FileBrowserError.failed(String(cString: strerror(errno))) }
        return target
    }

    @concurrent
    public func newFolder(in folder: URL, named name: String) async throws -> URL {
        guard namer.isValid(name) else { throw FileBrowserError.invalidName(name) }
        let free = namer.freeName(for: name, style: .number, taken: Self.names(in: folder))
        let target = folder.appendingPathComponent(free, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        } catch {
            throw FileBrowserError.failed(error.localizedDescription)
        }
        return target
    }

    @concurrent
    public func duplicate(_ urls: [URL]) async throws -> [URL] {
        var made: [URL] = []
        for url in urls {
            try Task.checkCancellation()
            let folder = url.deletingLastPathComponent()
            let free = namer.freeName(for: url.lastPathComponent, style: .copy, taken: Self.names(in: folder))
            let target = folder.appendingPathComponent(free)
            try Self.copy(url, to: target, progress: { _ in true })
            made.append(target)
        }
        return made
    }

    @concurrent
    public func trash(_ urls: [URL]) async throws -> [TrashedItem] {
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

    @concurrent
    public func putBack(_ items: [TrashedItem]) async throws -> [URL] {
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

    @concurrent
    public func move(_ pairs: [(from: URL, to: URL)]) async throws {
        // A destination that another pair is leaving (a swap or a shift of
        // numbered names) is taken until that pair moves: go through free
        // temporary names first, then to the real ones.
        let leaving = Set(pairs.map(\.from.path))
        if pairs.contains(where: { leaving.contains($0.to.path) && $0.to.path != $0.from.path }) {
            let parked = pairs.map { pair in
                (from: pair.from, to: pair.from.deletingLastPathComponent()
                    .appendingPathComponent(".cmux-move-\(UUID().uuidString)"))
            }
            try await move(parked)
            try await move(zip(parked, pairs).map { (from: $0.to, to: $1.to) })
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
        let job = FileTransferJob(sources: sources, folder: folder, mode: mode, namer: namer, resolve: resolve)
        // Progress events are snapshots and `.finished` is always the last one, so dropping the
        // oldest when the reader lags loses nothing it needs.
        return AsyncThrowingStream(bufferingPolicy: .bufferingNewest(16)) { continuation in
            let task = Task.detached(priority: .userInitiated) {
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
