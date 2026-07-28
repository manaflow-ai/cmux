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
    private let maxCoalescedDeliveries: Int
    private let maxConsecutiveBoundedFlushes: Int
    private let onDrainBoundExceeded: @MainActor @Sendable (Payload) -> Void
    private let onCircuitBreakerTripped: @MainActor @Sendable (Payload) -> Void

    private var pending: Payload?
    private var flushScheduled = false
    private var isDelivering = false
    private var consecutiveBoundedFlushes = 0

    /// Creates a focus-broadcast coalescer.
    ///
    /// - Parameters:
    ///   - maxCoalescedDeliveries: Upper bound on deliveries performed by a single
    ///     flush. Values below one are clamped to one.
    ///   - maxConsecutiveBoundedFlushes: Upper bound on consecutive flushes that
    ///     hit ``maxCoalescedDeliveries`` before the last pending payload is
    ///     dropped. Values below one are clamped to one.
    ///   - schedule: Schedules deferred main-actor flush work.
    ///   - onDrainBoundExceeded: Called with the still-pending payload when a
    ///     flush hits ``maxCoalescedDeliveries`` and defers to another turn.
    ///   - onCircuitBreakerTripped: Called with the dropped payload when a
    ///     non-converging cycle reaches ``maxConsecutiveBoundedFlushes``.
    ///   - deliver: Delivers one pending payload.
    public init(
        maxCoalescedDeliveries: Int = 8,
        maxConsecutiveBoundedFlushes: Int = 4,
        schedule: @escaping @MainActor @Sendable (@escaping @MainActor @Sendable () -> Void) -> Void,
        onDrainBoundExceeded: @escaping @MainActor @Sendable (Payload) -> Void = { _ in },
        onCircuitBreakerTripped: @escaping @MainActor @Sendable (Payload) -> Void = { _ in },
        deliver: @escaping @MainActor @Sendable (Payload) -> Void
    ) {
        self.maxCoalescedDeliveries = max(1, maxCoalescedDeliveries)
        self.maxConsecutiveBoundedFlushes = max(1, maxConsecutiveBoundedFlushes)
        self.schedule = schedule
        self.onDrainBoundExceeded = onDrainBoundExceeded
        self.onCircuitBreakerTripped = onCircuitBreakerTripped
        self.deliver = deliver
    }

    /// Records a payload for asynchronous, coalesced delivery.
    ///
    /// This method never delivers synchronously. If delivery is already in
    /// progress, the payload is recorded for the active drain loop instead of
    /// recursively scheduling more work.
    public func emit(_ payload: Payload) {
        pending = payload
        if isDelivering { return }
        if flushScheduled { return }
        flushScheduled = true
        schedule { @Sendable [weak self] in
            self?.flush()
        }
    }

    /// Delivers pending payloads in a bounded drain.
    ///
    /// Most callers should not call this directly; it is public so app-target
    /// wrappers and tests can drive an injected scheduler deterministically.
    public func flush() {
        flushScheduled = false
        guard !isDelivering else { return }
        isDelivering = true

        var iterations = 0
        var hitDeliveryBound = false
        while let next = pending {
            pending = nil
            iterations += 1
            if iterations > maxCoalescedDeliveries {
                pending = next
                hitDeliveryBound = true
                consecutiveBoundedFlushes += 1
                onDrainBoundExceeded(next)
                if consecutiveBoundedFlushes >= maxConsecutiveBoundedFlushes {
                    pending = nil
                    consecutiveBoundedFlushes = 0
                    onCircuitBreakerTripped(next)
                }
                break
            }
            deliver(next)
        }

        isDelivering = false
        if !hitDeliveryBound {
            consecutiveBoundedFlushes = 0
        }
        if pending != nil, !flushScheduled {
            flushScheduled = true
            schedule { @Sendable [weak self] in
                self?.flush()
            }
        }
    }
}
