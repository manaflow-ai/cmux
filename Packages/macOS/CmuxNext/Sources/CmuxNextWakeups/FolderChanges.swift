public import Foundation

/// Changes to the contents of some folders as an `AsyncStream`: one element per burst of
/// file-system events, never a poll (plans/cmux-next/idle-wakeups.md). A folder that does not
/// exist yet is watched through its nearest existing parent (a stand-in) and is watched itself
/// once made.
///
/// A stand-in's own changes are not the folder's: a missing `Backgrounds` folder is watched
/// through the app's Application Support folder, where the app writes its own files on every
/// prompt. An event from a stand-in yields only when a missing folder now exists (the watches
/// move down to it); otherwise it is dropped, and counted in the ledger under
/// `FolderChanges/stand-in`. Each element is counted under `FolderChanges/change`.
///
/// ``events()`` returns once the kernel has registered every watch, so a change made after that
/// call is seen even when the watch loop has not run yet (a store that calls ``events()`` and then
/// reads the folders misses nothing in between). Resuming a dispatch source only schedules that
/// registration, and a change before it completes is never delivered (dispatch_source(3)); each
/// watch's registration handler says when it has. Each element comes after the watch is armed and
/// registered again when it had to move, so a change between two elements is either seen by the
/// watch or happened before the element, and the consumer's work for the element (re-reading the
/// folders) covers it.
///
/// ```swift
/// for await _ in await FolderChanges(folders: [wallpapers, userImages]).events() { rebuild() }
/// ```
public struct FolderChanges: Sendable {
    /// The folders whose contents matter.
    public let folders: [URL]
    private let ledger: WakeupLedger
    private let queue: DispatchQueue

    /// - Parameters:
    ///   - folders: The folders whose contents matter; missing ones are watched through a parent.
    ///   - ledger: Where the watch counts its wakes.
    public init(folders: [URL], ledger: WakeupLedger = .shared) {
        self.init(folders: folders, ledger: ledger, queue: .global(qos: .utility))
    }

    /// - Parameter queue: Where the watches' handlers run (a test holds it suspended to delay
    ///   their registration).
    init(folders: [URL], ledger: WakeupLedger, queue: DispatchQueue) {
        self.folders = folders
        self.ledger = ledger
        self.queue = queue
    }

    /// One element after each burst of changes in any watched folder. Ends when the consumer
    /// stops iterating (the watches are cancelled with it). Returns once every watch is registered;
    /// a caller cancelled before then gets a finished stream and no watch.
    public func events() async -> AsyncStream<Void> {
        let targets = folders.map(\.path)
        let ledger = ledger, queue = queue
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        // Armed here, not in the loop: a utility task can start long after this returns under load,
        // and a change made before it armed was never seen (BackdropCatalogStoreTests hung on it).
        let first = await Self.arm(targets, on: queue)
        // A caller cancelled during the wait may never iterate, and the loop would hold the watch.
        guard !Task.isCancelled else {
            first.cancel()
            continuation.finish()
            return stream
        }
        // task-owner: the stream's watch loop; cancelled when the consumer stops iterating
        let loop = Task.detached(priority: .utility) {
            var armed = first
            // wakeup-allow: each pass waits for one file-system event in a watched folder, never polls
            while !Task.isCancelled {
                var iterator = armed.events.makeAsyncIterator()
                guard let event = await iterator.next() else { break }
                let now = Set(targets.map(nearestExistingFolder(of:)))
                let moved = now != armed.paths || event.flags.contains(.delete) || event.flags.contains(.rename)
                if !moved, !targets.contains(event.path) {
                    // A stand-in's own write: no watched folder appeared, so nothing of ours changed.
                    ledger.record("FolderChanges", reason: "stand-in")
                    continue
                }
                if moved {
                    let next = await Self.arm(targets, on: queue)
                    armed.cancel()
                    armed = next
                }
                ledger.record("FolderChanges", reason: "change")
                continuation.yield()
            }
            armed.cancel()
            continuation.finish()
        }
        continuation.onTermination = { _ in loop.cancel() }
        return stream
    }

    /// Watches the nearest existing folder of each of `targets`, and returns once the kernel has
    /// registered every watch (or the calling task is cancelled).
    private static func arm(_ targets: [String], on queue: DispatchQueue) async -> sending FolderWatch {
        let paths = Set(targets.map(nearestExistingFolder(of:)))
        let (events, continuation) = AsyncStream<FolderWatch.Event>.makeStream(bufferingPolicy: .bufferingNewest(8))
        // One element per watch whose registration finished, each yielded once; room for all of them,
        // since a registration can finish before the wait below starts.
        let (registered, registration) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(max(paths.count, 1)))
        // DispatchSource for file watching: no Foundation async equivalent (idle-wakeups.md).
        let sources = paths.compactMap { folder -> (any DispatchSourceFileSystemObject)? in
            let fd = open(folder, O_EVTONLY)
            guard fd >= 0 else { return nil }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete, .link],
                                                                   queue: queue)
            // The handler holds its source until cancel releases the handlers (FolderWatch.cancel).
            source.setEventHandler { continuation.yield(FolderWatch.Event(path: folder, flagBits: source.data.rawValue)) }
            // resume() only schedules the registration; events before it completes are missed
            // (dispatch_source(3)). This runs once it has, before any event handler.
            source.setRegistrationHandler { registration.yield() }
            source.setCancelHandler { close(fd) }
            source.resume()
            return source
        }
        var pending = sources.count
        // wakeup-allow: one element per watch registration, never a poll; ends when every watch is registered.
        if pending > 0 {
            for await _ in registered {
                pending -= 1
                if pending == 0 { break }
            }
        }
        registration.finish()
        return FolderWatch(paths: paths, events: events, sources: sources, finish: { continuation.finish() })
    }
}

/// The deepest existing folder on `path`, `path` itself included (`/` at worst).
private func nearestExistingFolder(of path: String) -> String {
    var directory = path
    var isFolder: ObjCBool = false
    while !(FileManager.default.fileExists(atPath: directory, isDirectory: &isFolder) && isFolder.boolValue),
          directory != "/", !directory.isEmpty {
        directory = (directory as NSString).deletingLastPathComponent
    }
    return directory.isEmpty ? "/" : directory
}
