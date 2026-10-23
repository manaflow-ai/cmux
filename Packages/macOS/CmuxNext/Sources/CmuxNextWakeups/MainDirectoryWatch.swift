import Darwin
import Foundation

/// Calls main-actor work on each change in a directory (an entry added, removed or renamed, or
/// the directory itself renamed or deleted) until it is released. An event, never a poll.
///
/// The one place a kqueue directory source on the main queue hands its events to main-actor
/// code: a socket client waits here for its socket to appear. Each event runs `changed` on the
/// main thread in the main queue's order, as a source made with `queue: .main` did. Releasing the
/// watch or calling ``cancel()`` stops it and closes its descriptor (`DispatchSource.cancel()` is
/// thread-safe), so the owner needs no deinit.
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

    /// Stops watching now (also happens when the watch is released).
    public func cancel() {
        source.cancel()
    }

    deinit {
        source.cancel()
    }
}
