internal import CmuxTerminalBackend
internal import Foundation

/// Owns one presentation-keyed renderer stream until explicit presentation teardown.
@MainActor
final class BackendOnlyRendererEventListener {
    private var generation = UUID()
    private var task: Task<Void, Never>?

    var isActive: Bool { task != nil }

    func start(
        events: AsyncStream<BackendRendererLifecycleEvent>,
        receive: @escaping @MainActor @Sendable (BackendRendererLifecycleEvent) async -> Void,
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

    /// Marks the current consumer obsolete after its session route was finished.
    /// The task is not cancelled so teardown RPCs invoked by its handler remain usable.
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
