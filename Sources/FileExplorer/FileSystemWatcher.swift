import Foundation

/// Watches a directory recursively for file system changes using FSEvents.
/// Debounces rapid changes and calls `onChange` on the main actor.
@MainActor
final class FileSystemWatcher {
    private var stream: FSEventStreamRef?
    private let debounceInterval: TimeInterval
    private var debounceTask: Task<Void, Never>?
    private var onChange: (() -> Void)?
    private var watchedPath: String?

    /// Context bridging `self` into the C callback.
    private final class StreamContext {
        weak var watcher: FileSystemWatcher?
        init(_ watcher: FileSystemWatcher) { self.watcher = watcher }
    }

    init(debounceInterval: TimeInterval = 0.3) {
        self.debounceInterval = debounceInterval
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }

    func start(watching url: URL, onChange: @escaping () -> Void) {
        let newPath = url.path
        if newPath == watchedPath, stream != nil {
            self.onChange = onChange
            return
        }
        stopStream()
        self.onChange = onChange
        self.watchedPath = newPath
        startStream(path: newPath)
    }

    func stop() {
        stopStream()
        debounceTask?.cancel()
        debounceTask = nil
        onChange = nil
        watchedPath = nil
    }

    // MARK: - FSEvents

    private func startStream(path: String) {
        let contextPtr = Unmanaged.passRetained(StreamContext(self)).toOpaque()

        var fsContext = FSEventStreamContext(
            version: 0,
            info: contextPtr,
            retain: nil,
            release: { info in
                guard let info else { return }
                Unmanaged<StreamContext>.fromOpaque(info).release()
            },
            copyDescription: nil
        )

        let paths = [path] as CFArray
        let flags: FSEventStreamCreateFlags =
            UInt32(kFSEventStreamCreateFlagUseCFTypes)
            | UInt32(kFSEventStreamCreateFlagFileEvents)
            | UInt32(kFSEventStreamCreateFlagNoDefer)

        guard let stream = FSEventStreamCreate(
            nil, Self.eventCallback, &fsContext, paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.2, flags
        ) else {
            Unmanaged<StreamContext>.fromOpaque(contextPtr).release()
            return
        }

        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.global(qos: .utility))
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
            return
        }
    }

    private func stopStream() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    private static let eventCallback: FSEventStreamCallback = {
        _, contextPtr, _, _, _, _ in
        guard let contextPtr else { return }
        let context = Unmanaged<StreamContext>.fromOpaque(contextPtr).takeUnretainedValue()
        Task { @MainActor in context.watcher?.handleEvents() }
    }

    private func handleEvents() {
        debounceTask?.cancel()
        let interval = debounceInterval
        debounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.onChange?()
        }
    }
}
