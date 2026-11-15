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
    /// Downstream demand is honored: a value reaching an emission point while
    /// the downstream has zero outstanding demand is conflated into a
    /// latest-value slot and delivered from `request(_:)` when demand
    /// arrives. Demand-driven subscribers such as `AsyncPublisher`
    /// (`.values`) request one value at a time; forwarding past zero demand
    /// trips Combine's "received an unexpected value" trap, which crashes in
    /// every build configuration.
    ///
    /// Thread-safe: upstream values, demand and cancellation may arrive on any
    /// thread; trailing emissions run on `scheduler`.
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
    /// Guards every `var` below. Values can arrive on any thread (the sidebar
    /// pipelines are fed by `@Published` properties of non-isolated classes),
    /// the trailing emission runs on `scheduler`, and `cancel()` can come from
    /// anywhere. Never held while calling downstream, upstream or
    /// `scheduler.schedule` (it only covers reads of `scheduler.now`), so it
    /// cannot invert the order of an upstream operator's lock.
    private let lock = NSLock()
    private var upstreamSubscription: Subscription?
    private var hasReceivedReplay = false
    private var windowStart: Context.SchedulerTimeType?
    private var pendingValue: Input?
    private var readyValue: Input?
    private var pendingCompletion: Subscribers.Completion<Never>?
    private var downstreamDemand: Subscribers.Demand = .none
    private var isDelivering = false
    private var trailingScheduled = false
    private var isCancelled = false

    init(downstream: Downstream, interval: Context.SchedulerTimeType.Stride, scheduler: Context) {
        self.downstream = downstream
        self.interval = interval
        self.scheduler = scheduler
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    func receive(subscription: Subscription) {
        withLock { upstreamSubscription = subscription }
        downstream.receive(subscription: self)
        guard !withLock({ isCancelled }) else {
            subscription.cancel()
            return
        }
        subscription.request(.unlimited)
    }

    private enum Arrival {
        case ignored
        case deliver
        case coalesced(scheduleAt: Context.SchedulerTimeType?)
    }

    func receive(_ input: Input) -> Subscribers.Demand {
        let arrival: Arrival = withLock {
            guard !isCancelled else { return .ignored }
            if !hasReceivedReplay {
                hasReceivedReplay = true
                readyValue = input
                return .deliver
            }
            let now = scheduler.now
            if let start = windowStart, now < start.advanced(by: interval) {
                pendingValue = input
                return .coalesced(scheduleAt: claimTrailingEmission(at: start.advanced(by: interval)))
            }
            // If a trailing emission was scheduled but its callback is
            // overdue (main run loop stalled past the deadline), this newer
            // value supersedes the stale pending one; drop it so the late
            // callback cannot emit it out of order after this value.
            pendingValue = nil
            windowStart = now
            readyValue = input
            return .deliver
        }
        switch arrival {
        case .ignored, .coalesced(scheduleAt: nil):
            break
        case .coalesced(scheduleAt: let deadline?):
            scheduleTrailingEmission(at: deadline)
        case .deliver:
            drainReadyValue()
        }
        return .none
    }

    func receive(completion: Subscribers.Completion<Never>) {
        let accepted: Bool = withLock {
            guard !isCancelled else { return false }
            pendingCompletion = completion
            if let value = pendingValue {
                pendingValue = nil
                readyValue = value
            }
            return true
        }
        if accepted {
            drainReadyValue()
        }
    }

    /// Marks the trailing emission as scheduled and returns its deadline, or
    /// nil when one is already pending. Called with the lock held.
    private func claimTrailingEmission(at deadline: Context.SchedulerTimeType) -> Context.SchedulerTimeType? {
        guard !trailingScheduled else { return nil }
        trailingScheduled = true
        return deadline
    }

    private func scheduleTrailingEmission(at deadline: Context.SchedulerTimeType) {
        scheduler.schedule(after: deadline) { [weak self] in
            self?.emitTrailing()
        }
    }

    private enum TrailingStep {
        case nothing
        case reschedule(Context.SchedulerTimeType)
        case deliver
    }

    private func emitTrailing() {
        let step: TrailingStep = withLock {
            trailingScheduled = false
            guard !isCancelled, let value = pendingValue else { return .nothing }
            // An overdue callback may fire inside a window that a newer leading
            // value opened; hold the pending value until that window's own
            // deadline instead of emitting early.
            if let start = windowStart {
                let deadline = start.advanced(by: interval)
                if scheduler.now < deadline {
                    trailingScheduled = true
                    return .reschedule(deadline)
                }
            }
            pendingValue = nil
            windowStart = scheduler.now
            readyValue = value
            return .deliver
        }
        switch step {
        case .nothing:
            break
        case .reschedule(let deadline):
            scheduleTrailingEmission(at: deadline)
        case .deliver:
            drainReadyValue()
        }
    }

    func request(_ demand: Subscribers.Demand) {
        guard demand > .none else { return }
        let accepted: Bool = withLock {
            guard !isCancelled else { return false }
            downstreamDemand += demand
            return true
        }
        if accepted {
            drainReadyValue()
        }
    }

    /// Delivers the ready value while there is demand. One caller delivers at a
    /// time; a value made ready meanwhile, on any thread, is picked up by the
    /// delivering loop, whose final empty check and `isDelivering = false`
    /// happen under one lock hold, so no value is stranded.
    private func drainReadyValue() {
        let claimed: Bool = withLock {
            guard !isDelivering else { return false }
            isDelivering = true
            return true
        }
        guard claimed else { return }

        while true {
            let next: Input? = withLock {
                guard !isCancelled, downstreamDemand > .none, let value = readyValue else {
                    isDelivering = false
                    return nil
                }
                readyValue = nil
                downstreamDemand -= .max(1)
                return value
            }
            guard let value = next else { break }
            let additionalDemand = downstream.receive(value)
            let cancelled: Bool = withLock {
                guard !isCancelled else {
                    isDelivering = false
                    return true
                }
                downstreamDemand += additionalDemand
                return false
            }
            if cancelled { return }
        }
        finishPendingCompletionIfPossible()
    }

    private func finishPendingCompletionIfPossible() {
        let completion: Subscribers.Completion<Never>? = withLock {
            guard !isCancelled,
                  !isDelivering,
                  readyValue == nil,
                  let completion = pendingCompletion
            else { return nil }

            pendingCompletion = nil
            // Combine completion is not demand-gated, but it cannot overtake a
            // buffered value. Once demand drains that value, completion follows.
            downstreamDemand = .none
            isCancelled = true
            upstreamSubscription = nil
            return completion
        }
        if let completion {
            downstream.receive(completion: completion)
        }
    }

    func cancel() {
        let upstream: Subscription? = withLock {
            isCancelled = true
            pendingValue = nil
            readyValue = nil
            pendingCompletion = nil
            downstreamDemand = .none
            defer { upstreamSubscription = nil }
            return upstreamSubscription
        }
        upstream?.cancel()
    }
}
