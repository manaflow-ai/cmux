import CmuxNextCompat
import CmuxNextWakeups
import Foundation

/// One copy or move run by ``FileOperator/transfer(_:to:mode:resolve:)``.
///
/// The job is async only to await the person's conflict answers; every file call (the size walk, the
/// conflict probe, Replace's trash, the copy or rename) runs as an item on the bulk files lane, which may
/// block and holds no cooperative pool thread (Chrome's `MayBlock` ThreadPool tasks, base/task/task_traits.h).
/// A copy can take minutes, so it never holds the serial files slot other Files calls wait on.
struct FileTransferJob: Sendable {
    let sources: [URL]
    let folder: URL
    let mode: TransferMode
    let namer: FileNamer
    let resolve: @Sendable (FileConflict) async -> ConflictAnswer
    let work: BackgroundWork

    /// What the lane found at a source's target before it is placed.
    private struct Probe: Sendable {
        var exists = false
        var bothFolders = false
    }

    /// The progress after one lane step, and the gate that lets copy progress through.
    private struct Placed: Sendable {
        var progress: TransferProgress
        var gate: TransferProgressGate
    }

    func run(_ emit: @escaping @Sendable (TransferEvent) -> Void) async throws {
        // The caller's cancel stops a copy between blocks (a lane thread has no task to cancel).
        let stop = FileWorkStop()
        try await withTaskCancellationHandler {
            try await transfer(emit, stop: stop)
        } onCancel: {
            stop.set()
        }
    }

    private func transfer(_ emit: @escaping @Sendable (TransferEvent) -> Void, stop: FileWorkStop) async throws {
        let sources = sources
        let sizes = try await lane { sources.map(Self.bytes(at:)) }
        var progress = TransferProgress(itemsDone: 0, itemsTotal: sources.count, bytesDone: 0,
                                        bytesTotal: sizes.reduce(0, +), current: nil)
        emit(.progress(progress))
        var gate = TransferProgressGate(bytesTotal: progress.bytesTotal)
        var placed: [URL: URL] = [:]
        var replaced: [TrashedItem] = []
        var standing: ConflictChoice?
        let folder = folder, mode = mode, namer = namer
        let folderPath = folder.standardizedFileURL.path

        for (source, size) in zip(sources, sizes) {
            try Task.checkCancellation()
            progress.current = source
            defer { progress.itemsDone += 1 }
            let sourcePath = source.standardizedFileURL.path
            if folderPath == sourcePath || folderPath.hasPrefix(sourcePath + "/") {
                throw FileBrowserError.failed("Cannot put a folder inside itself: \(source.lastPathComponent)")
            }
            var target = folder.appendingPathComponent(source.lastPathComponent)
            if mode == .move, source.deletingLastPathComponent().standardizedFileURL.path == folderPath {
                // Moving into the folder it is already in does nothing (Finder too).
                progress.bytesDone += size
                emit(.progress(progress))
                continue
            }
            let probe = try await lane { [target] in Self.probe(source, target: target) }
            if probe.exists {
                let choice: ConflictChoice
                if let standing {
                    choice = standing
                } else {
                    let answer = await resolve(FileConflict(source: source, existing: target, bothFolders: probe.bothFolders))
                    choice = answer.choice
                    if answer.applyToAll { standing = answer.choice }
                }
                switch choice {
                case .stop:
                    emit(.finished(placed: placed, replaced: replaced))
                    return
                case .skip:
                    progress.bytesDone += size
                    emit(.progress(progress))
                    continue
                case .keepBoth:
                    target = try await lane {
                        folder.appendingPathComponent(namer.freeName(for: source.lastPathComponent, style: .number,
                                                                     taken: FileOperator.names(in: folder)))
                    }
                case .replace:
                    replaced.append(try await lane { [target] in try Self.trash(target) })
                }
            }
            let base = progress.bytesDone
            let step = Placed(progress: progress, gate: gate)
            let done = try await lane { [target] in
                try Self.place(source, at: target, folder: folder, mode: mode, base: base, step: step, stop: stop, emit: emit)
            }
            (progress, gate) = (done.progress, done.gate)
            progress.bytesDone = base + size
            placed[source] = target
            emit(.progress(progress))
        }
        progress.current = nil
        emit(.finished(placed: placed, replaced: replaced))
    }

    /// One step of the job on the bulk files lane, at userBlocking: the person started the transfer and
    /// watches its progress.
    private func lane<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await work.run(.userBlocking, mayBlock: .bulkFiles, body)
    }

    /// Whether `target` is taken, and whether it and `source` are both folders; on the lane.
    private static func probe(_ source: URL, target: URL) -> Probe {
        var isDir: ObjCBool = false
        // SAFETY: `isDir` is a local that outlives the call; Foundation writes one ObjCBool through the pointer and
        // keeps no reference to it after returning.
        guard unsafe FileManager.checked.fileExists(atPath: target.path, isDirectory: &isDir) else { return Probe() }
        let sourceIsDir = (try? source.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        return Probe(exists: true, bothFolders: isDir.boolValue && sourceIsDir)
    }

    /// Replace's trash of the item already at `target`; on the lane.
    private static func trash(_ target: URL) throws -> TrashedItem {
        var trashed: NSURL?
        do {
            // SAFETY: `trashed` is a local that outlives the call; Foundation stores at most one autoreleased NSURL
            // through the pointer and keeps no reference to it.
            try unsafe FileManager.checked.trashItem(at: target, resultingItemURL: &trashed)
        } catch {
            throw FileBrowserError.failed(error.localizedDescription)
        }
        return TrashedItem(original: target, trashed: (trashed as URL?) ?? target)
    }

    /// Copies or moves `source` to `target`, emitting gated progress; on the lane.
    private static func place(_ source: URL, at target: URL, folder: URL, mode: TransferMode, base: Int64,
                              step: Placed, stop: FileWorkStop, emit: @Sendable (TransferEvent) -> Void) throws -> Placed {
        var step = step
        switch mode {
        case .move:
            if sameVolume(source, folder) {
                // SAFETY: rename reads the NUL-terminated copies of both paths made for the call.
                guard unsafe blockingRename(source.path, target.path) == 0 else {
                    throw FileBrowserError.posix(errno)
                }
            } else {
                try copy(source, to: target, base: base, step: &step, stop: stop, emit: emit)
                try? FileManager.checked.removeItem(at: source)
            }
        case .copy:
            try copy(source, to: target, base: base, step: &step, stop: stop, emit: emit)
        }
        return step
    }

    private static func copy(_ source: URL, to target: URL, base: Int64, step: inout Placed, stop: FileWorkStop,
                             emit: @Sendable (TransferEvent) -> Void) throws {
        var snapshot = step.progress
        var open = step.gate
        defer { step.gate = open }
        try FileOperator.copy(source, to: target) { copied in
            if stop.isSet { return false }
            snapshot.bytesDone = base + copied
            // copyfile reports every block; each event re-renders the Files pane on the main actor.
            if open.admits(snapshot.bytesDone) { emit(.progress(snapshot)) }
            return true
        }
        step.progress = snapshot
    }

    /// Bytes under `url` (files only; folders summed through their contents).
    static func bytes(at url: URL) -> Int64 {
        var info = stat()
        // SAFETY: lstat reads the NUL-terminated copy of the path made for the call and writes one struct stat into
        // `info`, a local live for the call.
        guard unsafe blockingLstat(url.path, &info) == 0 else { return 0 }
        if info.st_mode & S_IFMT != S_IFDIR { return Int64(info.st_size) }
        var total: Int64 = 0
        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey]
        guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) else { return 0 }
        for case let item as URL in walker {
            if let values = try? item.resourceValues(forKeys: Set(keys)), values.isRegularFile == true {
                total += Int64(values.fileSize ?? 0)
            }
        }
        return total
    }

    static func sameVolume(_ a: URL, _ b: URL) -> Bool {
        var sa = stat(), sb = stat()
        // SAFETY: lstat and stat read the NUL-terminated copies of the paths made for each call and write one struct
        // stat each into `sa` and `sb`, locals live for the calls.
        guard unsafe blockingLstat(a.path, &sa) == 0, unsafe blockingStat(b.path, &sb) == 0 else { return false }
        return sa.st_dev == sb.st_dev
    }
}

/// Lets a file's copy progress through once per `1 / steps` of the transfer's bytes. copyfile
/// reports each block it copies, so a large copy sent the Files pane tens of thousands of updates.
/// The progress after each item is always sent; this gates only the reports inside one file.
struct TransferProgressGate: Sendable {
    let step: Int64
    private var next: Int64 = 0

    init(bytesTotal: Int64, steps: Int64 = 200) {
        step = max(1, bytesTotal / max(1, steps))
    }

    /// Whether to send progress at `bytesDone`; true moves the next one a step further.
    mutating func admits(_ bytesDone: Int64) -> Bool {
        guard bytesDone >= next else { return false }
        next = bytesDone + step
        return true
    }
}
