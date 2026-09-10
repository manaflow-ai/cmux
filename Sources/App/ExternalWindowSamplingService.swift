import CoreGraphics
import Foundation

/// Owns a cancellable metadata sampler with at most one pending timer tick.
/// WindowServer reads run off the main actor; slow consumers cannot accumulate
/// work. Dispatch supplies timer events only, never synchronization or UI hops.
@MainActor
final class ExternalWindowSamplingService {
    private var timer: DispatchSourceTimer?
    private var task: Task<Void, Never>?
    private var ticks: AsyncStream<Void>.Continuation?

    func start(
        interval: DispatchTimeInterval,
        sample: @escaping @Sendable () -> ExternalApplicationWindowTracker.Snapshot?,
        deliver: @escaping @MainActor @Sendable (ExternalWindowSample) -> Void
    ) {
        stop()
        let (events, continuation) = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInteractive))
        timer.setEventHandler { continuation.yield() }
        timer.schedule(deadline: .now(), repeating: interval, leeway: .microseconds(250))
        self.timer = timer
        ticks = continuation
        task = Task.detached(priority: .userInitiated) {
            for await _ in events {
                guard !Task.isCancelled else { return }
                let startedAt = DispatchTime.now().uptimeNanoseconds
                let next = sample()
                guard !Task.isCancelled else { return }
                await deliver(ExternalWindowSample(startedAt: startedAt, snapshot: next))
            }
        }
        timer.resume()
    }

    func stop() {
        timer?.setEventHandler {}
        timer?.cancel()
        timer = nil
        ticks?.finish()
        ticks = nil
        task?.cancel()
        task = nil
    }
}
