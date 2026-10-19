import CoreGraphics
import Foundation

/// Owns a cancellable metadata sampler with at most one pending timer tick.
/// WindowServer reads run off the main actor; slow consumers cannot accumulate
/// work. Dispatch supplies timer events only, never synchronization or UI hops.
@MainActor
final class ExternalWindowSamplingService {
    private var task: Task<Void, Never>?

    deinit { task?.cancel() }

    func start(
        interval: DispatchTimeInterval,
        sample: @escaping @Sendable () -> ExternalApplicationWindowTracker.Snapshot?,
        deliver: @escaping @MainActor @Sendable (ExternalWindowSample) -> Void
    ) {
        stop()
        task = Task.detached(priority: .userInitiated) {
            guard !Task.isCancelled else { return }
            let (events, continuation) = AsyncStream<Void>.makeStream(
                bufferingPolicy: .bufferingNewest(1)
            )
            let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInteractive))
            timer.setEventHandler { continuation.yield() }
            timer.schedule(deadline: .now(), repeating: interval, leeway: .microseconds(250))
            timer.resume()
            defer {
                timer.setEventHandler {}
                timer.cancel()
                continuation.finish()
            }
            for await _ in events {
                guard !Task.isCancelled else { return }
                let startedAt = DispatchTime.now().uptimeNanoseconds
                let next = sample()
                guard !Task.isCancelled else { return }
                await deliver(ExternalWindowSample(startedAt: startedAt, snapshot: next))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}
