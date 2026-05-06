import Darwin
import Foundation

@MainActor
final class FilePreviewFileWatcher {
    enum Event: Equatable {
        case changed
        case movedOrDeleted
        case reappeared
    }

    private let url: URL
    private let queue: DispatchQueue
    private let onEvent: @MainActor (Event) -> Void

    private nonisolated let eventHopLock = NSLock()
    // SAFETY: these DispatchSource handles are `nonisolated(unsafe)` only because
    // Swift 6 deinit is nonisolated. Real source mutation stays on MainActor
    // lifecycle methods; deinit only cancels the last remaining handles.
    private nonisolated(unsafe) var fileSource: DispatchSourceFileSystemObject?
    private nonisolated(unsafe) var directorySource: DispatchSourceFileSystemObject?
    // SAFETY: event handlers replace this task from the watcher queue, while
    // MainActor cancellation/deinit also clear it. `eventHopLock` serializes both.
    private nonisolated(unsafe) var eventHopTask: Task<Void, Never>?
    private var pendingEvent: Event?
    private var eventFlushTask: Task<Void, Never>?
    private var isClosed = false

    init(url: URL, onEvent: @escaping @MainActor (Event) -> Void) {
        self.url = url
        self.onEvent = onEvent
        self.queue = DispatchQueue(label: "com.cmux.file-preview-watch", qos: .utility)
    }

    deinit {
        cancelEventHopTask()
        fileSource?.cancel()
        directorySource?.cancel()
    }

    func start() {
        guard !isClosed else { return }
        if FileManager.default.fileExists(atPath: url.path) {
            stopDirectoryWatcher()
            startFileWatcher()
        } else {
            stopFileWatcher()
            startDirectoryWatcher()
        }
    }

    func cancel() {
        isClosed = true
        cancelEventHopTask()
        eventFlushTask?.cancel()
        eventFlushTask = nil
        pendingEvent = nil
        stopFileWatcher()
        stopDirectoryWatcher()
    }

    private func enqueueEvent(_ event: Event) {
        guard !isClosed else { return }
        pendingEvent = Self.mergedEvent(pendingEvent, event)
        guard eventFlushTask == nil else { return }
        eventFlushTask = Task { [weak self] in
            await Task.yield()
            guard let self, !self.isClosed else { return }
            let event = self.pendingEvent
            self.pendingEvent = nil
            self.eventFlushTask = nil
            guard let event else { return }
            self.onEvent(event)
        }
    }

    static func mergedEvent(_ current: Event?, _ next: Event) -> Event {
        guard let current else { return next }
        switch next {
        case .reappeared, .movedOrDeleted:
            return next
        case .changed:
            return current == .changed ? .changed : current
        }
    }

    private func startFileWatcher() {
        guard fileSource == nil else { return }
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else {
            startDirectoryWatcher()
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename, .extend],
            queue: queue
        )

        source.setEventHandler { [weak self, weak source] in
            guard let flags = source?.data else { return }
            self?.scheduleFileEventHop(flags)
        }
        source.setCancelHandler { Darwin.close(fd) }
        source.resume()
        fileSource = source
    }

    private func stopFileWatcher() {
        fileSource?.cancel()
        fileSource = nil
    }

    private func handleFileEvent(_ flags: DispatchSource.FileSystemEvent) {
        guard !isClosed else { return }
        if flags.contains(.delete) || flags.contains(.rename) {
            stopFileWatcher()
            if FileManager.default.fileExists(atPath: url.path) {
                enqueueEvent(.reappeared)
                startFileWatcher()
            } else {
                enqueueEvent(.movedOrDeleted)
                startDirectoryWatcher()
            }
        } else {
            enqueueEvent(.changed)
        }
    }

    private func startDirectoryWatcher() {
        guard directorySource == nil else { return }
        let directoryURL = url.deletingLastPathComponent()
        let fd = open(directoryURL.path, O_EVTONLY)
        guard fd >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename, .extend],
            queue: queue
        )

        source.setEventHandler { [weak self] in
            self?.scheduleDirectoryEventHop()
        }
        source.setCancelHandler { Darwin.close(fd) }
        directorySource = source
        source.resume()

        if FileManager.default.fileExists(atPath: url.path) {
            handleDirectoryEvent()
        }
    }

    private func stopDirectoryWatcher() {
        directorySource?.cancel()
        directorySource = nil
    }

    private func handleDirectoryEvent() {
        guard !isClosed,
              FileManager.default.fileExists(atPath: url.path) else { return }
        stopDirectoryWatcher()
        enqueueEvent(.reappeared)
        startFileWatcher()
    }

    private nonisolated func scheduleFileEventHop(_ flags: DispatchSource.FileSystemEvent) {
        replaceEventHopTask(
            Task { @MainActor [weak self, flags] in
                guard !Task.isCancelled, let self, !self.isClosed else { return }
                self.handleFileEvent(flags)
            }
        )
    }

    private nonisolated func scheduleDirectoryEventHop() {
        replaceEventHopTask(
            Task { @MainActor [weak self] in
                guard !Task.isCancelled, let self, !self.isClosed else { return }
                self.handleDirectoryEvent()
            }
        )
    }

    private nonisolated func replaceEventHopTask(_ task: Task<Void, Never>) {
        eventHopLock.lock()
        let previousTask = eventHopTask
        eventHopTask = task
        eventHopLock.unlock()
        previousTask?.cancel()
    }

    private nonisolated func cancelEventHopTask() {
        eventHopLock.lock()
        let task = eventHopTask
        eventHopTask = nil
        eventHopLock.unlock()
        task?.cancel()
    }
}
