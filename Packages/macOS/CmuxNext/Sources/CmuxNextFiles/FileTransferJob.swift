import Foundation
import CmuxNextCompat

/// One copy or move run by ``FileOperator/transfer(_:to:mode:resolve:)``.
struct FileTransferJob: Sendable {
    let sources: [URL]
    let folder: URL
    let mode: TransferMode
    let namer: FileNamer
    let resolve: @Sendable (FileConflict) async -> ConflictAnswer

    func run(_ emit: (TransferEvent) -> Void) async throws {
        var progress = TransferProgress(itemsDone: 0, itemsTotal: sources.count, bytesDone: 0,
                                        bytesTotal: sources.reduce(0) { $0 + Self.bytes(at: $1) }, current: nil)
        emit(.progress(progress))
        var gate = TransferProgressGate(bytesTotal: progress.bytesTotal)
        var placed: [URL: URL] = [:]
        var replaced: [TrashedItem] = []
        var standing: ConflictChoice?
        let folderPath = folder.standardizedFileURL.path

        for source in sources {
            try Task.checkCancellation()
            let size = Self.bytes(at: source)
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
            if FileManager.checked.fileExists(atPath: target.path) {
                var isDir: ObjCBool = false
                // SAFETY: `isDir` is a local that outlives the call; Foundation writes one ObjCBool through the
                // pointer and keeps no reference to it after returning.
                unsafe FileManager.checked.fileExists(atPath: target.path, isDirectory: &isDir)
                let sourceIsDir = (try? source.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                let choice: ConflictChoice
                if let standing {
                    choice = standing
                } else {
                    let answer = await resolve(FileConflict(source: source, existing: target,
                                                            bothFolders: isDir.boolValue && sourceIsDir))
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
                    let free = namer.freeName(for: source.lastPathComponent, style: .number,
                                              taken: FileOperator.names(in: folder))
                    target = folder.appendingPathComponent(free)
                case .replace:
                    var trashed: NSURL?
                    do {
                        // SAFETY: `trashed` is a local that outlives the call; Foundation stores at most one
                        // autoreleased NSURL through the pointer and keeps no reference to it.
                        try unsafe FileManager.checked.trashItem(at: target, resultingItemURL: &trashed)
                    } catch {
                        throw FileBrowserError.failed(error.localizedDescription)
                    }
                    replaced.append(TrashedItem(original: target, trashed: (trashed as URL?) ?? target))
                }
            }
            let base = progress.bytesDone
            switch mode {
            case .move:
                if Self.sameVolume(source, folder) {
                    // SAFETY: rename reads the NUL-terminated copies of both paths made for the call.
                    guard unsafe blockingRename(source.path, target.path) == 0 else {
                        throw FileBrowserError.posix(errno)
                    }
                } else {
                    try copy(source, to: target, base: base, progress: &progress, gate: &gate, emit: emit)
                    try? FileManager.checked.removeItem(at: source)
                }
            case .copy:
                try copy(source, to: target, base: base, progress: &progress, gate: &gate, emit: emit)
            }
            progress.bytesDone = base + size
            placed[source] = target
            emit(.progress(progress))
        }
        progress.current = nil
        emit(.finished(placed: placed, replaced: replaced))
    }

    private func copy(_ source: URL, to target: URL, base: Int64, progress: inout TransferProgress,
                      gate: inout TransferProgressGate, emit: (TransferEvent) -> Void) throws {
        var snapshot = progress
        var open = gate
        defer { gate = open }
        try FileOperator.copy(source, to: target) { copied in
            if Task.isCancelled { return false }
            snapshot.bytesDone = base + copied
            // copyfile reports every block; each event re-renders the Files pane on the main actor.
            if open.admits(snapshot.bytesDone) { emit(.progress(snapshot)) }
            return true
        }
        progress = snapshot
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
struct TransferProgressGate {
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
