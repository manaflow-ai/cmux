import CoreServices
import Foundation
import CmuxNextFilesUI

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

    init(latency: CFTimeInterval = 0.2, started: (@Sendable () -> Void)? = nil) {
        self.latency = latency
        self.started = started
    }

    func changes(under folders: [URL]) -> AsyncStream<Void> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let paths = folders.map { FolderWatcherPath.real($0) }
            let box = FileTreeWatchStream(paths: paths, latency: latency, started: started, continuation: continuation)
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
        guard let resolved = realpath(standard, nil) else { return standard }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
