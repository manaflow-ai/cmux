import CoreServices
public import Foundation

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

    /// Makes a watcher. `latency` defaults to 50 ms.
    public init(latency: CFTimeInterval = 0.05) { self.latency = latency }

    public func changes(in folder: URL) -> AsyncStream<FolderChange> {
        // A reader that falls 64 batches behind gets `.rescan` (FolderWatchStream.deliver).
        AsyncStream(bufferingPolicy: .bufferingNewest(FolderWatchStream.buffer)) { continuation in
            let box = FolderWatchStream(folder: folder.standardizedFileURL.resolvingSymlinksInPath(),
                                        latency: latency, continuation: continuation)
            continuation.onTermination = { _ in box.stop() }
            box.start()
        }
    }
}
