import Foundation

/// Main-actor coordinator for off-main immutable snapshot loads. Refresh storms
/// coalesce to the newest requested generation, and stale loads never publish.
@MainActor
final class GenerationCoalescingSnapshotCache<Snapshot: Sendable> {
    typealias Loader = @Sendable () -> Snapshot?
    typealias LoaderPreparation = @MainActor @Sendable () -> Loader
    typealias InstallHandler = @MainActor @Sendable (Snapshot) -> Void

    private(set) var snapshot: Snapshot
    private let prepareLoader: LoaderPreparation
    private let installHandler: InstallHandler?
    private var requestedGeneration: UInt64 = 0
    private var isLoading = false
    private var loadTask: Task<Snapshot?, Never>?
    private var completionTask: Task<Void, Never>?
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        initialSnapshot: Snapshot,
        loader: @escaping Loader,
        installHandler: InstallHandler? = nil
    ) {
        snapshot = initialSnapshot
        prepareLoader = { loader }
        self.installHandler = installHandler
    }

    init(
        initialSnapshot: Snapshot,
        preparingLoader: @escaping LoaderPreparation,
        installHandler: InstallHandler? = nil
    ) {
        snapshot = initialSnapshot
        prepareLoader = preparingLoader
        self.installHandler = installHandler
    }

    deinit {
        loadTask?.cancel()
        completionTask?.cancel()
        for waiter in idleWaiters {
            waiter.resume()
        }
    }

    func requestRefresh() {
        requestedGeneration &+= 1
        guard !isLoading else { return }
        beginLoad(generation: requestedGeneration)
    }

    func waitUntilIdle() async {
        guard isLoading else { return }
        await withCheckedContinuation { continuation in
            idleWaiters.append(continuation)
        }
    }

    func cancel() {
        requestedGeneration &+= 1
        loadTask?.cancel()
        completionTask?.cancel()
        loadTask = nil
        completionTask = nil
        isLoading = false
        let waiters = idleWaiters
        idleWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    func replaceSnapshotWithoutInstalling(_ replacement: Snapshot) {
        snapshot = replacement
    }

    private func beginLoad(generation: UInt64) {
        isLoading = true
        let loader = prepareLoader()
        let loadTask: Task<Snapshot?, Never> = Task.detached(priority: .utility) {
            guard !Task.isCancelled else { return nil }
            return loader()
        }
        self.loadTask = loadTask
        completionTask = Task { @MainActor [weak self] in
            let replacement = await loadTask.value
            guard !Task.isCancelled else { return }
            self?.finishLoad(replacement, generation: generation)
        }
    }

    private func finishLoad(
        _ replacement: Snapshot?,
        generation: UInt64
    ) {
        loadTask = nil
        completionTask = nil
        guard generation == requestedGeneration else {
            beginLoad(generation: requestedGeneration)
            return
        }

        if let replacement {
            snapshot = replacement
            installHandler?(replacement)
        }
        guard generation == requestedGeneration else {
            beginLoad(generation: requestedGeneration)
            return
        }
        isLoading = false
        let waiters = idleWaiters
        idleWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }
}

typealias KeyboardLayoutSnapshotCache = GenerationCoalescingSnapshotCache<KeyboardLayoutSnapshot>
