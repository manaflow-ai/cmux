internal import CmuxTerminalBackend
internal import Foundation

/// Owns one exact surface interaction stream until explicit presentation teardown.
@MainActor
final class BackendOnlyTerminalInteractionModeListener {
    private var generation = UUID()
    private var task: Task<Void, Never>?

    deinit {
        task?.cancel()
    }

    var isActive: Bool { task != nil }

    func start(
        events: AsyncStream<BackendTerminalInteractionModeChanged>,
        receive: @escaping @MainActor @Sendable (
            BackendTerminalInteractionModeChanged
        ) async -> Void,
        onEnd: @escaping @MainActor @Sendable () async -> Void
    ) {
        precondition(task == nil)
        let generation = UUID()
        self.generation = generation
        task = Task { @MainActor [weak self] in
            for await event in events {
                guard let self, self.generation == generation else { return }
                await receive(event)
            }
            guard let self, self.generation == generation else { return }
            let cancelled = Task.isCancelled
            self.task = nil
            if !cancelled {
                await onEnd()
            }
        }
    }

    func retire() {
        generation = UUID()
        task = nil
    }

    func cancel() {
        generation = UUID()
        let prior = task
        task = nil
        prior?.cancel()
    }
}
