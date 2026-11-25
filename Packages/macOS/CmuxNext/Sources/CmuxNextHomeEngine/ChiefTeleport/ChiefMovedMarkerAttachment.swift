import CmuxNextCompat
import Foundation

/// The file-system watch behind ``ChiefMovedMarkerWatcher``: one vnode source on the deepest of the
/// home's `state` folder, the home, or its parent that exists, re-armed after every event (the folder
/// it watched may be the one that appeared or went away), then a wake on the stream.
// Wraps a DispatchSourceFileSystemObject (no Foundation async equivalent; the documented carve-out).
nonisolated final class ChiefMovedMarkerAttachment: Sendable {
    /// The source now armed, and whether the stream ended.
    private struct State {
        var source: (any DispatchSourceFileSystemObject)?
        var cancelled = false
    }

    private let folders: [URL]
    private let continuation: AsyncStream<Void>.Continuation
    /// Event delivery for the source (not a lock: the state is in `state`).
    private let queue = DispatchQueue(label: "cmux.chief.movedMarker", qos: .utility)
    // Lock carve-out: a short swap of the armed source, called from the synchronous source handler and
    // the stream's termination handler; an actor would add a hop between an event and its re-arm.
    private let state = Mutex(State())

    init(home: URL, continuation: AsyncStream<Void>.Continuation) {
        folders = [home.appendingPathComponent("state", isDirectory: true), home, home.deletingLastPathComponent()]
        self.continuation = continuation
    }

    /// Arms the first watch on the caller's thread, so a change right after `changes()` returns is seen.
    func start() {
        arm()
    }

    /// Stops the watch (the stream ended).
    func cancel() {
        state.withLock { state in
            state.cancelled = true
            state.source?.cancel()
            state.source = nil
        }
    }

    private func arm() {
        state.withLock { state in
            state.source?.cancel()
            state.source = nil
            guard !state.cancelled else { return }
            state.source = watch()
        }
    }

    /// A resumed source on the first folder that opens, or nil when none does.
    private func watch() -> (any DispatchSourceFileSystemObject)? {
        for folder in folders {
            let descriptor = open(folder.path, O_EVTONLY)
            guard descriptor >= 0 else { continue }
            let watch = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
                                                                  eventMask: [.write, .delete, .rename, .link], queue: queue)
            watch.setEventHandler { [weak self] in self?.fired() }
            watch.setCancelHandler { close(descriptor) }
            watch.resume()
            return watch
        }
        return nil
    }

    private func fired() {
        arm()
        continuation.yield()
    }
}
