import Combine
import Foundation

// CoalesceLatestPublisher and CoalesceLatestInner are one operator: the
// Inner is the publisher's subscription and shares its file-private access
// boundary. Splitting the Inner into its own file would force widening
// `private` to `internal` for an implementation detail, so the pair
// intentionally lives in this single file.

// MARK: - Leading-edge coalescing

extension Publisher where Failure == Never {
    /// Coalesces bursts while keeping the leading edge synchronous.
    ///
    /// Combine's `throttle` schedules every emission, including the first,
    /// onto the scheduler, so even an isolated value is deferred to the next
    /// run-loop turn and a subscriber never observes a synchronous emission.
    /// The sidebar's immediate observation contract requires the opposite:
    /// the current-state replay a subscriber receives from `@Published`
    /// upstreams, and the first change after an idle period, must both arrive
    /// in the same run-loop turn; only the tail of a burst may be deferred.
    ///
    /// Semantics per subscription:
    /// - The first value (the `@Published` replay of current state) is
    ///   forwarded synchronously and does not open a coalesce window, so a
    ///   change made right after subscribing is still synchronous.
    /// - A value arriving when no window is open is forwarded synchronously
    ///   and opens a window of `interval`.
    /// - Values arriving inside an open window are coalesced: the latest one
    ///   is emitted when the window closes (on `scheduler`), which opens the
    ///   next window.
    ///
    /// Not thread-safe: intended for main-thread streams with `RunLoop.main`.
    /// Demand-limited subscribers receive the latest ready value only after
    /// requesting it, so this operator is safe to bridge into `AsyncSequence`.
    func coalesceLatest<Context: Scheduler>(
        for interval: Context.SchedulerTimeType.Stride,
        scheduler: Context
    ) -> AnyPublisher<Output, Never> {
        CoalesceLatestPublisher(upstream: self, interval: interval, scheduler: scheduler)
            .eraseToAnyPublisher()
    }
}

private struct CoalesceLatestPublisher<Upstream: Publisher, Context: Scheduler>: Publisher
    where Upstream.Failure == Never {
    typealias Output = Upstream.Output
    typealias Failure = Never

    let upstream: Upstream
    let interval: Context.SchedulerTimeType.Stride
    let scheduler: Context

    func receive<S: Subscriber>(subscriber: S) where S.Input == Output, S.Failure == Never {
        upstream.subscribe(CoalesceLatestInner(
            downstream: subscriber,
            interval: interval,
            scheduler: scheduler
        ))
    }
}

private final class CoalesceLatestInner<Downstream: Subscriber, Context: Scheduler>: Subscriber, Subscription
    where Downstream.Failure == Never {
    typealias Input = Downstream.Input
    typealias Failure = Never

    private let downstream: Downstream
    private let interval: Context.SchedulerTimeType.Stride
    private let scheduler: Context
    private var upstreamSubscription: Subscription?
    private var hasReceivedReplay = false
    private var windowStart: Context.SchedulerTimeType?
    private var pendingValue: Input?
    private var readyValue: Input?
    private var downstreamDemand: Subscribers.Demand = .none
    private var isDelivering = false
    private var trailingScheduled = false
    private var isCancelled = false

    init(downstream: Downstream, interval: Context.SchedulerTimeType.Stride, scheduler: Context) {
        self.downstream = downstream
        self.interval = interval
        self.scheduler = scheduler
    }

    func receive(subscription: Subscription) {
        upstreamSubscription = subscription
        downstream.receive(subscription: self)
        guard !isCancelled else {
            subscription.cancel()
            return
        }
        subscription.request(.unlimited)
    }

    func receive(_ input: Input) -> Subscribers.Demand {
        guard !isCancelled else { return .none }
        if !hasReceivedReplay {
            hasReceivedReplay = true
            enqueueForDelivery(input)
            return .none
        }
        let now = scheduler.now
        if let start = windowStart, now < start.advanced(by: interval) {
            pendingValue = input
            scheduleTrailingEmission(at: start.advanced(by: interval))
        } else {
            // If a trailing emission was scheduled but its callback is
            // overdue (main run loop stalled past the deadline), this newer
            // value supersedes the stale pending one; drop it so the late
            // callback cannot emit it out of order after this value.
            pendingValue = nil
            windowStart = now
            enqueueForDelivery(input)
        }
        return .none
    }

    func receive(completion: Subscribers.Completion<Never>) {
        guard !isCancelled else { return }
        if let value = pendingValue {
            pendingValue = nil
            enqueueForDelivery(value)
        }
        guard !isCancelled else { return }
        // Combine completion is not demand-gated. If no demand remains, the
        // buffered latest value cannot legally precede completion and drops.
        readyValue = nil
        isCancelled = true
        downstream.receive(completion: completion)
        upstreamSubscription = nil
    }

    private func scheduleTrailingEmission(at deadline: Context.SchedulerTimeType) {
        guard !trailingScheduled else { return }
        trailingScheduled = true
        scheduler.schedule(after: deadline) { [weak self] in
            self?.emitTrailing()
        }
    }

    private func emitTrailing() {
        trailingScheduled = false
        guard !isCancelled, let value = pendingValue else { return }
        // An overdue callback may fire inside a window that a newer leading
        // value opened; hold the pending value until that window's own
        // deadline instead of emitting early.
        if let start = windowStart {
            let deadline = start.advanced(by: interval)
            if scheduler.now < deadline {
                scheduleTrailingEmission(at: deadline)
                return
            }
        }
        pendingValue = nil
        windowStart = scheduler.now
        enqueueForDelivery(value)
    }

    func request(_ demand: Subscribers.Demand) {
        guard !isCancelled, demand > .none else { return }
        downstreamDemand += demand
        drainReadyValue()
    }

    private func enqueueForDelivery(_ value: Input) {
        readyValue = value
        drainReadyValue()
    }

    private func drainReadyValue() {
        guard !isDelivering else { return }
        isDelivering = true
        defer { isDelivering = false }

        while !isCancelled,
              downstreamDemand > .none,
              let value = readyValue {
            readyValue = nil
            downstreamDemand -= .max(1)
            let additionalDemand = downstream.receive(value)
            guard !isCancelled else { return }
            downstreamDemand += additionalDemand
        }
    }

    func cancel() {
        isCancelled = true
        pendingValue = nil
        readyValue = nil
        downstreamDemand = .none
        upstreamSubscription?.cancel()
        upstreamSubscription = nil
    }
}
