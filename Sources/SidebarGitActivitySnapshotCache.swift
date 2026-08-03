import Foundation

/// Coalesces sidebar settings refreshes onto one detached load and publishes
/// only the newest complete immutable policy on the main actor.
@MainActor
final class SidebarGitActivitySnapshotCache {
    typealias Loader = @Sendable () -> SidebarGitActivitySnapshot?
    typealias InstallHandler = @MainActor @Sendable (SidebarGitActivitySnapshot) -> Void

    private(set) var snapshot: SidebarGitActivitySnapshot
    private let loader: Loader
    private let installHandler: InstallHandler?
    private var requestedGeneration: UInt64 = 0
    private var isLoading = false
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        initialSnapshot: SidebarGitActivitySnapshot = .disabled,
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
        _ replacement: SidebarGitActivitySnapshot?,
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
