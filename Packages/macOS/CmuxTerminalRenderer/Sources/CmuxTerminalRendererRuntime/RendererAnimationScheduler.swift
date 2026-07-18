internal import Foundation

/// Cancels one scheduled animation wake without retaining a presentation.
public protocol RendererAnimationCancellation: Sendable {
    func cancel()
}

/// Schedules one worker-local animation wake. Implementations never repeat;
/// the runtime explicitly schedules the next wake only after a bounded frame
/// was accepted, which lets lease backpressure stop the clock completely.
public protocol RendererAnimationScheduling: Sendable {
    func schedule(
        _ operation: @escaping @Sendable () async -> Void
    ) -> any RendererAnimationCancellation
}

/// Default 60 Hz one-shot scheduler used only inside the renderer process.
public struct RendererDisplayAnimationScheduler: RendererAnimationScheduling {
    public let frameInterval: Duration

    public init(frameInterval: Duration = .milliseconds(16)) {
        self.frameInterval = frameInterval
    }

    public func schedule(
        _ operation: @escaping @Sendable () async -> Void
    ) -> any RendererAnimationCancellation {
        let cancellation = RendererAnimationTaskCancellation()
        let interval = frameInterval
        let task = Task {
            do {
                try await Task.sleep(for: interval)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await operation()
        }
        cancellation.install(task)
        return cancellation
    }
}

private final class RendererAnimationTaskCancellation:
    RendererAnimationCancellation,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var isCancelled = false

    func install(_ task: Task<Void, Never>) {
        lock.lock()
        if isCancelled {
            lock.unlock()
            task.cancel()
            return
        }
        self.task = task
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        isCancelled = true
        let task = self.task
        self.task = nil
        lock.unlock()
        task?.cancel()
    }
}
