import CoreServices
import Foundation
import CmuxNextFilesUI
import CmuxNextCompat
import CmuxNextWakeups

/// FSEvents under a few folders, delivered as an `AsyncStream` (no polling):
/// the Files tree's folder and its repository's `.git` folder. FSEvents
/// coalesces a burst (``latency``) into one value. Inside a `.git` folder only
/// the index, HEAD and refs count (a `git add`, a commit, a checkout), never
/// objects or logs, so `git status` reading the repository never wakes it.
nonisolated struct FileTreeWatcher: FileTreeWatching {
    /// The coalescing latency in seconds.
    var latency: CFTimeInterval
    /// Called once the FSEvents stream runs (tests wait for it before changing a file).
    var started: (@Sendable () -> Void)?
    /// The line that made the watcher: each of its watches is in the arm census under it (Debug and bench builds,
    /// startup-queue.py arms, p08-startup-085).
    private let file: StaticString
    private let line: UInt

    init(latency: CFTimeInterval = 0.2, started: (@Sendable () -> Void)? = nil, file: StaticString = #fileID, line: UInt = #line) {
        self.latency = latency
        self.started = started
        self.file = file
        self.line = line
    }

    func changes(under folders: [URL]) -> AsyncStream<Void> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let paths = folders.map { FolderWatcherPath.real($0) }
            let box = FileTreeWatchStream(paths: paths, latency: latency, started: started,
                                          census: ArmCensusWatch(.watcher, owner: "FileTreeWatcher", file: file, line: line),
                                          continuation: continuation)
            continuation.onTermination = { _ in box.stop() }
            box.start()
        }
    }

    /// Whether an event at `path` is a change the tree shows: anything outside `.git`, and the
    /// index, HEAD and refs inside it.
    static func counts(_ path: String) -> Bool {
        guard let range = path.range(of: "/.git/") ?? (path.hasSuffix("/.git") ? path.range(of: "/.git") : nil) else { return true }
        let inside = path[range.upperBound...]
        return inside == "index" || inside == "HEAD" || inside.hasPrefix("refs/") || inside == "packed-refs"
    }
}

/// The kernel's path of a folder (`realpath(3)`), as FSEvents reports paths.
nonisolated enum FolderWatcherPath {
    static func real(_ folder: URL) -> String {
        let standard = folder.standardizedFileURL.path
        // SAFETY: with a nil buffer realpath returns a NUL-terminated path it malloc'd (or nil), which String
        // copies before the deferred free; nothing else holds it.
        guard let resolved = unsafe blockingRealpath(standard, nil) else { return standard }
        defer { unsafe free(resolved) }
        return unsafe String(cString: resolved)
    }
}
