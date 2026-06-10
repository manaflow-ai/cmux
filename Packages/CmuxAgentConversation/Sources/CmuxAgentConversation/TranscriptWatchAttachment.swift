import Foundation

/// The kqueue plumbing behind ``TranscriptFileWatcher``: one live subscription
/// to filesystem events for a single transcript path.
///
/// It watches the file itself for writes/extends and, when the file is missing
/// or gets renamed/deleted out from under it (log rotation), falls back to
/// watching the parent directory until a file reappears at the path, then
/// re-attaches. Every observed change yields one signal on the continuation;
/// consumers re-read the file and diff, so signals carry no payload and
/// kqueue's natural coalescing bounds the signal rate.
///
/// Wraps `DispatchSourceFileSystemObject`; every mutation of the stored
/// sources happens on `queue` (the sanctioned file-watching carve-out), so the
/// type is safe to reference across concurrency domains.
final class TranscriptWatchAttachment: @unchecked Sendable {
    /// The watched transcript path.
    private let path: String

    /// The signal sink; one `()` per observed filesystem change.
    private let continuation: AsyncStream<Void>.Continuation

    // Serial queue used for DispatchSource event delivery; all stored-source
    // mutation is confined to it (file-watching carve-out, no async equivalent).
    private let queue = DispatchQueue(label: "cmux.agent-conversation.transcript-watch")

    /// The active watch on the transcript file, when it exists.
    private var fileSource: (any DispatchSourceFileSystemObject)?

    /// The fallback watch on the parent directory while the file is missing.
    private var directorySource: (any DispatchSourceFileSystemObject)?

    /// Set once `stop()` runs; suppresses any re-attach still in flight.
    private var stopped = false

    /// Creates an attachment feeding the given continuation.
    ///
    /// - Parameters:
    ///   - path: The transcript file path to watch.
    ///   - continuation: The stream continuation to signal on changes.
    init(path: String, continuation: AsyncStream<Void>.Continuation) {
        self.path = path
        self.continuation = continuation
    }

    /// Begins watching. Safe to call once, from any thread.
    func start() {
        queue.async { self.attachToFile() }
    }

    /// Stops watching, closes descriptors, and finishes the stream.
    /// Safe to call from any thread (it is the stream's `onTermination`).
    func stop() {
        queue.async { self.teardown() }
    }

    /// Opens the file and installs the kqueue source, or falls back to the
    /// parent-directory watch when the file does not exist yet.
    private func attachToFile() {
        guard !stopped else { return }
        directorySource?.cancel()
        directorySource = nil

        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else {
            attachToDirectory()
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .delete, .rename, .link],
            queue: queue
        )
        source.setEventHandler { [weak self] in
            guard let self, !self.stopped else { return }
            let events = source.data
            if events.contains(.delete) || events.contains(.rename) {
                // The path no longer names this inode (rotation/replacement);
                // re-open whatever now lives at the path, or wait for it.
                // Re-attach BEFORE signaling so a write landing right after
                // the consumer's re-read is caught by the new watch.
                self.fileSource?.cancel()
                self.fileSource = nil
                self.attachToFile()
            }
            self.continuation.yield(())
        }
        source.setCancelHandler { close(descriptor) }
        fileSource = source
        source.activate()
    }

    /// Watches the parent directory for the transcript file to (re)appear,
    /// then signals once and re-attaches to the file.
    private func attachToDirectory() {
        guard !stopped else { return }
        let directory = (path as NSString).deletingLastPathComponent
        let descriptor = open(directory, O_EVTONLY)
        // No directory either: nothing to watch. The stream stays open but
        // silent, mirroring the one-shot source's behavior for a missing file.
        guard descriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write],
            queue: queue
        )
        source.setEventHandler { [weak self] in
            guard let self, !self.stopped else { return }
            guard access(self.path, F_OK) == 0 else { return }
            self.directorySource?.cancel()
            self.directorySource = nil
            // Attach to the file BEFORE signaling: writes that land after the
            // consumer's re-read are then caught by the file watch, so no
            // change can fall into the gap between signal and attach.
            self.attachToFile()
            self.continuation.yield(())
        }
        source.setCancelHandler { close(descriptor) }
        directorySource = source
        source.activate()
    }

    /// Cancels both sources (closing their descriptors) and finishes the stream.
    private func teardown() {
        stopped = true
        fileSource?.cancel()
        fileSource = nil
        directorySource?.cancel()
        directorySource = nil
        continuation.finish()
    }
}
