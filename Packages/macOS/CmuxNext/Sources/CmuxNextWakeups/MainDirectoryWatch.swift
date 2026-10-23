import Darwin
import Foundation

/// Calls main-actor work on each change in a directory (an entry added, removed or renamed, or
/// the directory itself renamed or deleted) until it is released. An event, never a poll.
///
/// The packages' socket clients (AgentActivitySocketSource, AgentTurnStateFeed,
/// SocketTasksSource) wait here for their socket to appear. Each event runs `changed` on the main
/// thread in the main queue's order, as a source made with `queue: .main` did. A callback, not an
/// `AsyncStream`: the event stays synchronous on the main queue, where a consumer task would run
/// the work as a later main-actor job. Releasing the watch stops it on the releasing thread
/// (`DispatchSource.cancel()` is thread-safe; the descriptor closes in the cancel handler on the
/// main queue), so the owner's deinit has no body. A main-actor owner still declares
/// `nonisolated deinit {}`, so its release does not hop to the main actor (cx-t7hu;
/// check-concurrency.sh enforces it).
///
/// ```swift
/// directoryWatch = MainDirectoryWatch(directory) { [weak self] in self?.connect() }
/// ```
public final class MainDirectoryWatch {
    private let source: any DispatchSourceFileSystemObject

    /// Starts watching `directory`; nil when it cannot be opened (it does not exist).
    ///
    /// - Parameters:
    ///   - directory: The directory to watch.
    ///   - changed: Main-actor work for each change, on the main thread.
    public init?(_ directory: String, _ changed: @escaping @MainActor @Sendable () -> Void) {
        let descriptor = open(directory, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        // wakeup-allow: a kqueue directory event (no timer, no poll); DispatchSource has no async-native replacement.
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename, .delete],
                                                               queue: .main)
        source.setEventHandler {
            // main-proof: the source delivers on the main queue (queue: .main above).
            MainActor.assumeIsolated { changed() }
        }
        source.setCancelHandler { close(descriptor) }
        self.source = source
        source.resume()
    }

    deinit {
        source.cancel()
    }
}
