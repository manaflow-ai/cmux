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

    private nonisolated(unsafe) var fileSource: DispatchSourceFileSystemObject?
    private nonisolated(unsafe) var directorySource: DispatchSourceFileSystemObject?
    private var pendingEvent: Event?
    private var eventFlushTask: Task<Void, Never>?
    private var isClosed = false

    init(url: URL, onEvent: @escaping @MainActor (Event) -> Void) {
        self.url = url
        self.onEvent = onEvent
        self.queue = DispatchQueue(label: "com.cmux.file-preview-watch", qos: .utility)
    }

    deinit {
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

    private static func mergedEvent(_ current: Event?, _ next: Event) -> Event {
        guard let current else { return next }
        if current == .movedOrDeleted || next == .movedOrDeleted {
            return .movedOrDeleted
        }
        if current == .reappeared || next == .reappeared {
            return .reappeared
        }
        return .changed
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
            Task { @MainActor [weak self, flags] in
                self?.handleFileEvent(flags)
            }
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
            Task { @MainActor [weak self] in
                self?.handleDirectoryEvent()
            }
        }
        source.setCancelHandler { Darwin.close(fd) }
        source.resume()
        directorySource = source
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
}
