import CmuxNextWakeups
import CoreServices
public import Foundation
import CmuxNextCompat

/// What changed in a watched folder.
public enum FolderChange: Sendable, Equatable {
    /// The direct children with these names changed (created, removed, renamed or modified).
    case items([String])
    /// Too much changed to say which: list the folder again.
    case rescan
}

/// Watches one folder for changes to its direct children: the seam the Files
/// model observes through. Tests yield changes by hand.
public protocol FolderWatching: Sendable {
    /// A stream of changes to `folder`'s children. Ending the iteration
    /// (cancelling the task) stops the watch.
    func changes(in folder: URL) -> AsyncStream<FolderChange>
}

/// File-level FSEvents on one folder, delivered as an `AsyncStream`.
///
/// FSEvents coalesces bursts (50 ms latency) and reports item paths, so a
/// change to one file in a 100 000-item folder updates one row instead of
/// listing the folder again. Events below the folder's direct children are
/// dropped; a dropped-events or root-changed flag becomes ``FolderChange/rescan``.
public struct FolderWatcher: FolderWatching {
    /// The coalescing latency in seconds.
    public var latency: CFTimeInterval

    /// Changes held for a reader that lags; past this the oldest is dropped and a rescan follows.
    static let bufferLimit = 64

    /// The line that made the watcher: each of its watches is in the arm census under it (Debug and bench builds,
    /// startup-queue.py arms, p08-startup-085).
    private let file: StaticString
    private let line: UInt

    /// Makes a watcher. `latency` defaults to 50 ms; leave `file` and `line` to their defaults.
    public init(latency: CFTimeInterval = 0.05, file: StaticString = #fileID, line: UInt = #line) {
        self.latency = latency
        self.file = file
        self.line = line
    }

    public func changes(in folder: URL) -> AsyncStream<FolderChange> {
        // Bounded: when the reader lags so far that a change is dropped, a rescan follows it.
        AsyncStream(bufferingPolicy: .bufferingNewest(Self.bufferLimit)) { continuation in
            let census = ArmCensusWatch(.watcher, owner: "FolderWatcher", file: file, line: line)
            let box = FolderWatchStream(folder: Self.realFolder(folder), latency: latency, census: census,
                                        continuation: continuation)
            continuation.onTermination = { _ in box.stop() }
            box.start()
        }
    }

    /// The kernel's path for `folder` (`realpath(3)`), as FSEvents reports paths: /private/var/...
    /// for the temp directory. `resolvingSymlinksInPath()` would give /var/..., and every child
    /// event would then fail the parent check. A folder that does not resolve keeps its path.
    static func realFolder(_ folder: URL) -> URL {
        let standard = folder.standardizedFileURL
        // SAFETY: realpath reads the NUL-terminated copy of the path made for the call and, given no buffer, returns
        // a NUL-terminated path it allocated, read once here and freed once on return.
        guard let resolved = unsafe blockingRealpath(standard.path, nil) else { return standard }
        defer { unsafe free(resolved) }
        return URL(fileURLWithPath: unsafe String(cString: resolved), isDirectory: true)
    }
}
