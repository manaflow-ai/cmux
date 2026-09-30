import CmuxFoundation
import CmuxGit

/// Parks native registration completions so tests can interleave owner changes.
actor WatcherRegistrationGate {
    private let arrivals: AsyncStream<Int>
    private let arrivalContinuation: AsyncStream<Int>.Continuation
    private var nextID = 0
    private var pending: [Int: CheckedContinuation<RecursivePathWatcher?, Never>] = [:]

    init() {
        (arrivals, arrivalContinuation) = AsyncStream<Int>.makeStream()
    }

    func register(_ descriptor: GitWorkspaceMetadataWatchDescriptor) async -> RecursivePathWatcher? {
        let id = nextID
        nextID += 1
        return await withCheckedContinuation { continuation in
            pending[id] = continuation
            arrivalContinuation.yield(id)
        }
    }

    func nextArrival() async -> Int? {
        var iterator = arrivals.makeAsyncIterator()
        return await iterator.next()
    }

    func complete(_ id: Int, with watcher: RecursivePathWatcher?) {
        pending.removeValue(forKey: id)?.resume(returning: watcher)
    }
}
