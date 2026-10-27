import Dispatch
import Foundation

/// A kernel watch of one folder's entries: its handler runs on the given queue after a burst of changes (an entry
/// made, removed or renamed, a subfolder made, the folder itself removed or renamed), never on a poll.
/// ``RetryWake`` watches the daemon socket's folder with it.
///
/// Darwin: a vnode source on an event-only descriptor (`O_EVTONLY`, events write, link, delete and rename).
/// Linux: an inotify descriptor with one watch, read by a dispatch read source that drains its queued events,
/// as Chromium's FilePathWatcher does on each platform (base/files/file_path_watcher_kqueue.cc,
/// base/files/file_path_watcher_inotify.cc).
struct FolderEventSource {
    /// A folder opened for events and not yet watched: start it (``init(_:queue:handler:)``) or ``discard()`` it.
    struct Opened: Sendable {
        fileprivate let descriptor: Int32

        /// Opens `path` for events; nil when it does not open (not a folder, no permission, no descriptor left).
        init?(path: String) {
            #if canImport(Darwin)
            // SAFETY: open reads the NUL-terminated copy of `path` Swift makes for the call.
            let descriptor = unsafe open(path, O_EVTONLY | O_CLOEXEC)
            guard descriptor >= 0 else { return nil }
            #else
            let descriptor = inotify_init1(Int32(truncatingIfNeeded: IN_NONBLOCK | IN_CLOEXEC))
            guard descriptor >= 0 else { return nil }
            // SAFETY: inotify_add_watch reads the NUL-terminated copy of `path` Swift makes for the call.
            let watch = unsafe inotify_add_watch(descriptor, path, Self.watchedEvents)
            guard watch >= 0 else {
                _ = close(descriptor)
                return nil
            }
            #endif
            self.descriptor = descriptor
        }

        /// Closes a folder that was opened and never watched.
        func discard() {
            _ = close(descriptor)
        }

        #if !canImport(Darwin)
        /// The inotify events that match the vnode source's write, link, delete and rename on a folder: an entry
        /// made, removed or moved in or out (write; Darwin's link count change of a new subfolder is one of
        /// these), and the folder itself removed or moved (delete, rename). IN_ONLYDIR refuses a path that is
        /// not a folder, as the vnode watch is only ever put on one.
        private static let watchedEvents = UInt32(truncatingIfNeeded:
            IN_CREATE | IN_DELETE | IN_MOVED_FROM | IN_MOVED_TO | IN_DELETE_SELF | IN_MOVE_SELF | IN_ONLYDIR)
        #endif
    }

    private let source: any DispatchSourceProtocol

    /// Starts watching `opened`; `handler` runs on `queue` after each burst of changes. The watch owns the
    /// descriptor from here on and closes it when cancelled.
    init(_ opened: Opened, queue: DispatchQueue, handler: @escaping @Sendable () -> Void) {
        let descriptor = opened.descriptor
        #if canImport(Darwin)
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .link, .delete, .rename], queue: queue)
        source.setEventHandler { handler() }
        #else
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler {
            Self.drainEvents(descriptor)
            handler()
        }
        #endif
        source.setCancelHandler { _ = close(descriptor) }
        source.resume()
        self.source = source
    }

    /// Stops the watch and closes its descriptor. Later calls do nothing.
    func cancel() {
        source.cancel()
    }

    #if !canImport(Darwin)
    /// Reads every queued inotify event, so the read source rests until the next change: one handler call per
    /// burst, as the vnode source coalesces. The descriptor is non-blocking, so the last read returns EAGAIN
    /// instead of waiting.
    private static func drainEvents(_ descriptor: Int32) {
        var buffer = [UInt8](repeating: 0, count: 4096)
        // wakeup-allow: bounded: reads only the events already queued; EAGAIN (none left) or an error ends it
        while true {
            // SAFETY: read writes at most buffer.count bytes into the array's own storage, which the closure
            // lends for the call only.
            let count = unsafe buffer.withUnsafeMutableBytes { unsafe read(descriptor, $0.baseAddress, $0.count) }
            if count > 0 { continue }
            if count < 0, errno == EINTR { continue }
            return
        }
    }
    #endif
}
