import Foundation

/// Main-actor coordinator for off-main keyboard-layout loads. Refresh storms
/// coalesce to the newest requested generation, and stale loads never publish.
@MainActor
final class KeyboardLayoutSnapshotCache {
    typealias Loader = @Sendable () -> KeyboardLayoutSnapshot?
    typealias InstallHandler = @MainActor @Sendable (KeyboardLayoutSnapshot) -> Void

    private(set) var snapshot: KeyboardLayoutSnapshot
    private let loader: Loader
    private let installHandler: InstallHandler?
    private var requestedGeneration: UInt64 = 0
    private var isLoading = false
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        initialSnapshot: KeyboardLayoutSnapshot = .usBootstrap,
        loader: @escaping Loader,
        installHandler: InstallHandler? = nil
    ) {
        snapshot = initialSnapshot
        self.loader = loader
        self.installHandler = installHandler
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

    private func beginLoad(generation: UInt64) {
        isLoading = true
        let loader = self.loader
        Task { @MainActor [weak self] in
            let replacement = await Task.detached(priority: .utility) {
                loader()
            }.value
            self?.finishLoad(replacement, generation: generation)
        }
    }

    private func finishLoad(
        _ replacement: KeyboardLayoutSnapshot?,
        generation: UInt64
    ) {
        guard generation == requestedGeneration else {
            beginLoad(generation: requestedGeneration)
            return
        }

        if let replacement {
            snapshot = replacement
            installHandler?(replacement)
        }
        isLoading = false
        let waiters = idleWaiters
        idleWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }
}
