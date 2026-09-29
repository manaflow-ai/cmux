import Foundation

/// One search to run: what to find, where, and on which backend.
public struct FileSearchRequest: @unchecked Sendable {
    public var query: FileSearchQuery
    public var rootPath: String
    /// Identifies the backend's target (local, an SSH host, a Cloud VM).
    /// Two requests are the same search only when this matches.
    public var scopeIdentity: String
    /// The file tree's revision; a new revision re-runs an identical query.
    public var contentRevision: Int
    public var backend: any FileSearchBackend

    public init(
        query: FileSearchQuery,
        rootPath: String,
        scopeIdentity: String,
        contentRevision: Int = 0,
        backend: any FileSearchBackend
    ) {
        self.query = query
        self.rootPath = rootPath
        self.scopeIdentity = scopeIdentity
        self.contentRevision = contentRevision
        self.backend = backend
    }

    /// Equality of everything but the backend object.
    public func isSameSearch(as other: FileSearchRequest) -> Bool {
        query == other.query && rootPath == other.rootPath &&
            scopeIdentity == other.scopeIdentity && contentRevision == other.contentRevision
    }
}

public enum FileSearchPhase: Hashable, Sendable {
    case idle
    case searching
    case finished(FileSearchCompletion)
}

/// What the results view must apply, in order.
public enum FileSearchEngineEvent: Equatable, Sendable {
    /// The tree was emptied; reload everything.
    case reset
    /// Rows were added to the tree.
    case changed(FileSearchTreeChange)
    /// ``FileSearchEngine/phase`` changed.
    case phase(FileSearchPhase)
}

/// Owns the current search: debounces requests, cancels superseded ones,
/// and applies streamed batches to ``tree`` at most once per frame.
@MainActor
public final class FileSearchEngine {
    public let tree: FileSearchResultTree
    public private(set) var phase: FileSearchPhase = .idle
    public private(set) var activeRequest: FileSearchRequest?
    public var onEvent: ((FileSearchEngineEvent) -> Void)?

    public let matchLimit: Int
    private let clock: any Clock<Duration>
    private let debounceInterval: Duration
    private let frameInterval: Duration
    private var generation = 0
    private var debounceTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var drainTask: Task<Void, Never>?

    /// - Parameters:
    ///   - clock: Times the debounce and frame pacing. Tests inject a manual clock.
    ///   - relativePath: Maps a match path to the path shown on its file row.
    public init(
        clock: any Clock<Duration> = ContinuousClock(),
        debounceInterval: Duration = .milliseconds(200),
        frameInterval: Duration = .milliseconds(16),
        matchLimit: Int = 100_000,
        relativePath: @escaping (String) -> String
    ) {
        self.clock = clock
        self.debounceInterval = debounceInterval
        self.frameInterval = frameInterval
        self.matchLimit = matchLimit
        self.tree = FileSearchResultTree(relativePath: relativePath)
    }

    public var isSearching: Bool { phase == .searching }

    /// Starts `request` after the debounce interval unless another request
    /// arrives first. A request identical to the running one is ignored.
    public func schedule(_ request: FileSearchRequest) {
        debounceTask?.cancel()
        debounceTask = nil
        if isRunning(request) { return }
        let clock = self.clock
        let interval = debounceInterval
        debounceTask = Task { [weak self] in
            do {
                try await Self.sleep(clock, for: interval)
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            self.debounceTask = nil
            self.start(request)
        }
    }

    /// Starts `request` now, cancelling any running or pending search. A
    /// request identical to the running one is ignored.
    public func start(_ request: FileSearchRequest) {
        debounceTask?.cancel()
        debounceTask = nil
        if isRunning(request) { return }
        stopRunningSearch()
        generation += 1
        let searchGeneration = generation
        activeRequest = request
        tree.removeAll()
        onEvent?(.reset)

        guard !request.query.isEmpty, !request.rootPath.isEmpty else {
            setPhase(.idle)
            return
        }
        if request.query.regexSyntaxError != nil {
            setPhase(.finished(.failed(.invalidRegex(nil))))
            return
        }
        setPhase(.searching)

        let mailbox = FileSearchBatchMailbox()
        let backend = request.backend
        let query = request.query
        let rootPath = request.rootPath
        let limit = matchLimit
        searchTask = Task.detached(priority: .userInitiated) {
            let completion = await backend.search(query: query, rootPath: rootPath, matchLimit: limit, sink: mailbox)
            mailbox.finish(completion)
        }
        let clock = self.clock
        let frame = frameInterval
        drainTask = Task { [weak self] in
            for await _ in mailbox.signals {
                guard let self, self.generation == searchGeneration else { return }
                let drained = mailbox.drain()
                if !drained.groups.isEmpty {
                    let change = self.tree.apply(drained.groups)
                    self.onEvent?(.changed(change))
                }
                if let completion = drained.completion {
                    self.finish(generation: searchGeneration, completion: completion)
                    return
                }
                do {
                    try await Self.sleep(clock, for: frame)
                } catch {
                    return
                }
            }
        }
    }

    /// Stops any pending or running search. `clearResults` also empties the tree.
    public func cancel(clearResults: Bool) {
        debounceTask?.cancel()
        debounceTask = nil
        let wasSearching = isSearching
        stopRunningSearch()
        generation += 1
        activeRequest = nil
        if clearResults {
            tree.removeAll()
            onEvent?(.reset)
            setPhase(.idle)
        } else if wasSearching {
            setPhase(.idle)
        }
    }

    private func isRunning(_ request: FileSearchRequest) -> Bool {
        guard isSearching, let activeRequest else { return false }
        return activeRequest.isSameSearch(as: request)
    }

    private func finish(generation searchGeneration: Int, completion: FileSearchCompletion) {
        guard searchGeneration == generation else { return }
        searchTask = nil
        drainTask = nil
        setPhase(.finished(completion))
    }

    private func stopRunningSearch() {
        searchTask?.cancel()
        searchTask = nil
        drainTask?.cancel()
        drainTask = nil
    }

    private func setPhase(_ next: FileSearchPhase) {
        guard phase != next else { return }
        phase = next
        onEvent?(.phase(next))
    }

    private nonisolated static func sleep<C: Clock>(_ clock: C, for duration: Duration) async throws
        where C.Duration == Duration {
        try await clock.sleep(until: clock.now.advanced(by: duration), tolerance: nil)
    }
}
