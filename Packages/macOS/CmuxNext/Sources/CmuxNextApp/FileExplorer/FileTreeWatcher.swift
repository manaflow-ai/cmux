import CoreServices
import Foundation
import CmuxNextFilesUI
import CmuxNextWakeups

/// FSEvents under a few folders, delivered as an `AsyncStream` (no polling):
/// the Files tree's folder and its repository's `.git` folder. FSEvents
/// coalesces a burst (``latency``) into one value. Inside a `.git` folder only
/// the index, HEAD and refs count (a `git add`, a commit, a checkout), never
/// objects or logs, so `git status` reading the repository never wakes it.
///
/// Under Energy Saver a stream coalesces ``EnergyPolicy/pollStretch`` times longer, so an agent or a
/// build writing the tree wakes the app 4 times less often. A running stream follows the policy: when
/// the stretch changes, its FSEvents stream is made again with the new latency.
nonisolated struct FileTreeWatcher: FileTreeWatching {
    /// The coalescing latency in seconds, outside Energy Saver.
    var latency: CFTimeInterval
    /// The app's Energy Saver policy (`MainWorkScheduler.energy`); nil keeps ``latency``.
    var energy: EnergyPolicySource?
    /// Called with its latency each time an FSEvents stream runs (tests wait for it before changing a file).
    var started: (@Sendable (_ latency: CFTimeInterval) -> Void)?
    /// The line that made the watcher: each of its watches is in the arm census under it (Debug and bench builds,
    /// startup-queue.py arms, p08-startup-085).
    private let file: StaticString
    private let line: UInt

    init(latency: CFTimeInterval = 0.2, energy: EnergyPolicySource? = nil, started: (@Sendable (_ latency: CFTimeInterval) -> Void)? = nil,
         file: StaticString = #fileID, line: UInt = #line) {
        self.latency = latency
        self.energy = energy
        self.started = started
        self.file = file
        self.line = line
    }

    /// The latency a stream coalesces with now: ``latency`` times the saver's poll stretch.
    var currentLatency: CFTimeInterval { Self.stretched(latency, in: energy?.policy ?? .normal) }

    /// `base` times `policy`'s poll stretch.
    static func stretched(_ base: CFTimeInterval, in policy: EnergyPolicy) -> CFTimeInterval {
        base * CFTimeInterval(policy.pollStretch)
    }

    func changes(under folders: [URL]) -> AsyncStream<Void> {
        let base = latency, energy = energy, started = started
        let census = ArmCensusWatch(.watcher, owner: "FileTreeWatcher", file: file, line: line)
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let paths = folders.map { FolderWatcherPath.real($0) }
            let box = FileTreeWatchStream(paths: paths, latency: Self.stretched(base, in: energy?.policy ?? .normal),
                                          started: started, census: census, continuation: continuation)
            let policy = energy?.observe { [weak box] policy in box?.setLatency(Self.stretched(base, in: policy)) }
            continuation.onTermination = { _ in
                policy?.cancel()
                box.stop()
            }
            box.start()
            // A policy change before the observer was in place still reaches the stream (an equal latency does nothing).
            if let energy { box.setLatency(Self.stretched(base, in: energy.policy)) }
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
        guard let resolved = unsafe realpath(standard, nil) else { return standard }
        defer { unsafe free(resolved) }
        return unsafe String(cString: resolved)
    }
}
