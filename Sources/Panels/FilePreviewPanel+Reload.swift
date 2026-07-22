import CmuxFoundation
import Darwin
import Foundation

struct FilePreviewLatestRequestState<Request: Sendable>: Sendable {
    struct Submission: Sendable {
        let id: Int
        let request: Request
    }

    struct Completion: Sendable {
        let shouldDeliver: Bool
        let next: Submission?
    }

    private var nextID = 0
    private var active: Submission?
    private var pending: Submission?

    mutating func submit(_ request: Request) -> Submission? {
        nextID &+= 1
        let submission = Submission(id: nextID, request: request)
        guard active != nil else {
            active = submission
            return submission
        }
        pending = submission
        return nil
    }

    mutating func complete(id: Int) -> Completion {
        guard active?.id == id else {
            return Completion(shouldDeliver: false, next: nil)
        }
        let shouldDeliver = pending == nil && id == nextID
        active = nil
        let next = pending
        pending = nil
        active = next
        return Completion(shouldDeliver: shouldDeliver, next: next)
    }

    mutating func cancel() {
        nextID &+= 1
        pending = nil
    }
}

@MainActor
final class FilePreviewLatestLoadCoordinator<Output: Sendable> {
    private struct Request: Sendable {
        let load: @Sendable () -> Output
        let completion: @MainActor @Sendable (Output) -> Void
    }

    private let queue: OperationQueue
    private var state = FilePreviewLatestRequestState<Request>()

    init(name: String) {
        let queue = OperationQueue()
        queue.name = name
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        self.queue = queue
    }

    func submit(
        load: @escaping @Sendable () -> Output,
        completion: @escaping @MainActor @Sendable (Output) -> Void
    ) {
        let request = Request(load: load, completion: completion)
        guard let submission = state.submit(request) else { return }
        start(submission)
    }

    func cancel() {
        state.cancel()
    }

    private func start(_ submission: FilePreviewLatestRequestState<Request>.Submission) {
        queue.addOperation { [weak self] in
            let output = submission.request.load()
            Task { @MainActor [weak self] in
                self?.complete(submission, output: output)
            }
        }
    }

    private func complete(
        _ submission: FilePreviewLatestRequestState<Request>.Submission,
        output: Output
    ) {
        let transition = state.complete(id: submission.id)
        if transition.shouldDeliver {
            submission.request.completion(output)
        }
        if let next = transition.next {
            start(next)
        }
    }
}

struct FilePreviewFileState: Equatable {
    private let exists: Bool
    private let device: dev_t
    private let inode: ino_t
    private let size: off_t
    private let modificationTime: timespec
    private let statusChangeTime: timespec

    static func capture(path: String) -> FilePreviewFileState {
        var attributes = stat()
        guard stat(path, &attributes) == 0 else {
            return FilePreviewFileState(
                exists: false,
                device: 0,
                inode: 0,
                size: 0,
                modificationTime: timespec(),
                statusChangeTime: timespec()
            )
        }
        return FilePreviewFileState(
            exists: true,
            device: attributes.st_dev,
            inode: attributes.st_ino,
            size: attributes.st_size,
            modificationTime: attributes.st_mtimespec,
            statusChangeTime: attributes.st_ctimespec
        )
    }

    static func == (lhs: FilePreviewFileState, rhs: FilePreviewFileState) -> Bool {
        lhs.exists == rhs.exists
            && lhs.device == rhs.device
            && lhs.inode == rhs.inode
            && lhs.size == rhs.size
            && lhs.modificationTime.tv_sec == rhs.modificationTime.tv_sec
            && lhs.modificationTime.tv_nsec == rhs.modificationTime.tv_nsec
            && lhs.statusChangeTime.tv_sec == rhs.statusChangeTime.tv_sec
            && lhs.statusChangeTime.tv_nsec == rhs.statusChangeTime.tv_nsec
    }
}

extension FilePreviewPanel {
    /// Starts one panel-scoped filesystem observation task. `FileWatcher`
    /// handles atomic replacement and delete/recreate recovery for the path.
    func startWatchingForFileChanges() {
        stopWatchingForFileChanges()
        lastObservedFileState = .capture(path: filePath)
        let watcher = FileWatcher(path: filePath)
        fileChangeWatcher = watcher
        let events = watcher.events
        fileChangeTask = Task { @MainActor [weak self] in
            for await _ in events {
                guard let self, !self.isClosed else { break }
                self.handleObservedFileChange()
            }
        }
    }

    @discardableResult
    func handleObservedFileChange() -> Task<Void, Never>? {
        let state = FilePreviewFileState.capture(path: filePath)
        guard state != lastObservedFileState else { return nil }
        lastObservedFileState = state
        fileChangeReloadTask?.cancel()
        let task = reloadFromDisk()
        fileChangeReloadTask = task
        return task
    }

    func stopWatchingForFileChanges() {
        fileChangeTask?.cancel()
        fileChangeTask = nil
        fileChangeReloadTask?.cancel()
        fileChangeReloadTask = nil
        // Dropping the watcher cancels its DispatchSources.
        fileChangeWatcher = nil
    }
}
