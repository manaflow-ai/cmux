/// Coalesces and bounds main-actor focus broadcasts.
///
/// The coalescer is payload-agnostic: callers provide the scheduler, delivery
/// closure, and diagnostics. This keeps the re-entrancy/circuit-breaker policy
/// testable in the package while leaving app-specific notification wiring at the
/// composition edge.
@MainActor
public final class FocusSurfaceBroadcastCoalescer<Payload: Sendable> {
    private let deliver: @MainActor @Sendable (Payload) -> Void
    private let schedule: @MainActor @Sendable (@escaping @MainActor @Sendable () -> Void) -> Void
    private let scheduleAfterCircuitBreaker: @MainActor @Sendable (@escaping @MainActor @Sendable () -> Void) -> Void
    private let maxCoalescedDeliveries: Int
    private let maxConsecutiveBoundedFlushes: Int
    private let onDrainBoundExceeded: @MainActor @Sendable (Payload) -> Void
    private let onCircuitBreakerTripped: @MainActor @Sendable (Payload) -> Void

    private var pending: Payload?
    private var flushScheduled = false
    private var circuitBreakerFlushScheduled = false
    private var circuitBreakerOpen = false
    private var isDelivering = false
    private var consecutiveBoundedFlushes = 0

    /// Creates a focus-broadcast coalescer.
    ///
    /// - Parameters:
    ///   - maxCoalescedDeliveries: Upper bound on deliveries performed by a single
    ///     flush. Values below one are clamped to one.
    ///   - maxConsecutiveBoundedFlushes: Upper bound on consecutive flushes that
    ///     hit ``maxCoalescedDeliveries`` before the still-pending payload is moved
    ///     to the circuit-breaker scheduler. Values below one are clamped to one.
    ///   - schedule: Schedules deferred main-actor flush work.
    ///   - scheduleAfterCircuitBreaker: Schedules one retained-payload recovery
    ///     after the circuit breaker trips. Defaults to ``schedule``.
    ///   - onDrainBoundExceeded: Called with the still-pending payload when a
    ///     flush hits ``maxCoalescedDeliveries`` and defers to another turn.
    ///   - onCircuitBreakerTripped: Called with the retained pending payload when
    ///     a non-converging cycle reaches ``maxConsecutiveBoundedFlushes``.
    ///   - deliver: Delivers one pending payload.
    public init(
        maxCoalescedDeliveries: Int = 8,
        maxConsecutiveBoundedFlushes: Int = 4,
        schedule: @escaping @MainActor @Sendable (@escaping @MainActor @Sendable () -> Void) -> Void,
        scheduleAfterCircuitBreaker: (@MainActor @Sendable (@escaping @MainActor @Sendable () -> Void) -> Void)? = nil,
        onDrainBoundExceeded: @escaping @MainActor @Sendable (Payload) -> Void = { _ in },
        onCircuitBreakerTripped: @escaping @MainActor @Sendable (Payload) -> Void = { _ in },
        deliver: @escaping @MainActor @Sendable (Payload) -> Void
    ) {
        self.maxCoalescedDeliveries = max(1, maxCoalescedDeliveries)
        self.maxConsecutiveBoundedFlushes = max(1, maxConsecutiveBoundedFlushes)
        self.schedule = schedule
        self.scheduleAfterCircuitBreaker = scheduleAfterCircuitBreaker ?? schedule
        self.onDrainBoundExceeded = onDrainBoundExceeded
        self.onCircuitBreakerTripped = onCircuitBreakerTripped
        self.deliver = deliver
    }

    /// Records a payload for asynchronous, coalesced delivery.
    ///
    /// This method never delivers synchronously. If delivery is already in
    /// progress, the payload is recorded for the active drain loop instead of
    /// recursively scheduling more work. If the circuit breaker is open, only an
    /// external emit closes it and schedules immediate work; synchronous emits from
    /// recovery delivery remain pending without rescheduling the loop.
    public func emit(_ payload: Payload) {
        pending = payload
        if isDelivering { return }
        if circuitBreakerOpen {
            circuitBreakerOpen = false
            consecutiveBoundedFlushes = 0
        }
        scheduleImmediateFlush()
    }

    /// Delivers pending payloads in a bounded drain.
    ///
    /// Most callers should not call this directly; it is public so app-target
    /// wrappers and tests can drive an injected scheduler deterministically.
    public func flush() {
        flushScheduled = false
        guard !isDelivering else { return }
        if circuitBreakerOpen {
            flushCircuitBreakerRecovery()
            return
        }
        isDelivering = true

        var iterations = 0
        var hitDeliveryBound = false
        var hitCircuitBreaker = false
        while let next = pending {
            pending = nil
            iterations += 1
            if iterations > maxCoalescedDeliveries {
                hitDeliveryBound = true
                consecutiveBoundedFlushes += 1
                onDrainBoundExceeded(next)
                if consecutiveBoundedFlushes >= maxConsecutiveBoundedFlushes {
                    pending = next
                    hitCircuitBreaker = true
                    circuitBreakerOpen = true
                    consecutiveBoundedFlushes = 0
                    onCircuitBreakerTripped(next)
                } else {
                    pending = next
                }
                break
            }
            deliver(next)
        }

        isDelivering = false
        if !hitDeliveryBound {
            consecutiveBoundedFlushes = 0
        }
        if pending != nil {
            if hitCircuitBreaker {
                scheduleCircuitBreakerFlush()
            } else {
                scheduleImmediateFlush()
            }
        }
    }

    private func flushCircuitBreakerRecovery() {
        guard let next = pending else {
            circuitBreakerOpen = false
            consecutiveBoundedFlushes = 0
            return
        }
        pending = nil
        isDelivering = true
        deliver(next)
        isDelivering = false
        consecutiveBoundedFlushes = 0
        if pending == nil {
            circuitBreakerOpen = false
        }
    }

    private func scheduleImmediateFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        schedule { @Sendable [weak self] in
            self?.flush()
        }
    }

    private func scheduleCircuitBreakerFlush() {
        guard !circuitBreakerFlushScheduled else { return }
        circuitBreakerFlushScheduled = true
        scheduleAfterCircuitBreaker { @Sendable [weak self] in
            guard let self else { return }
            self.circuitBreakerFlushScheduled = false
            self.flush()
        }
    }
}
