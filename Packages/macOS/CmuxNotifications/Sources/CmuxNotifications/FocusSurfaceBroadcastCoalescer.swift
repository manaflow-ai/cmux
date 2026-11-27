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
    private let maxConsecutiveCircuitDeliveries: Int
    private let maxCircuitBreakerRecoveryDeliveries: Int
    private let belongsToSameCircuit: @MainActor @Sendable (Payload, Payload) -> Bool
    private let onDrainBoundExceeded: @MainActor @Sendable (Payload) -> Void
    private let onCircuitBreakerTripped: @MainActor @Sendable (Payload) -> Void

    private var pending: Payload?
    private var flushScheduled = false
    private var circuitBreakerOpen = false
    private var isDelivering = false
    private var consecutiveBoundedFlushes = 0
    private var circuitDeliveryReference: Payload?
    private var consecutiveCircuitDeliveries = 0
    private var circuitBreakerReference: Payload?
    private var circuitBreakerRecoveryDeliveriesRemaining = 0

    /// Creates a focus-broadcast coalescer.
    ///
    /// - Parameters:
    ///   - maxCoalescedDeliveries: Upper bound on deliveries performed by a single
    ///     flush. Values below one are clamped to one.
    ///   - maxConsecutiveBoundedFlushes: Upper bound on consecutive flushes that
    ///     hit ``maxCoalescedDeliveries`` before the still-pending payload is moved
    ///     to the circuit-breaker scheduler. Values below one are clamped to one.
    ///   - maxConsecutiveCircuitDeliveries: Upper bound on deliveries for payloads
    ///     that belong to the same logical feedback circuit, including deferred
    ///     emits that arrive after the active delivery stack has unwound. Defaults
    ///     to `maxCoalescedDeliveries * maxConsecutiveBoundedFlushes`.
    ///   - maxCircuitBreakerRecoveryDeliveries: Upper bound on retained same-circuit
    ///     payloads delivered after the circuit breaker trips. Defaults to
    ///     `maxCoalescedDeliveries`, so legitimate finite convergence can publish a
    ///     final payload while non-converging feedback remains bounded.
    ///   - belongsToSameCircuit: Returns whether two payloads belong to the same
    ///     logical feedback circuit. Payloads in different circuits are treated as
    ///     new external work and close any open breaker.
    ///   - schedule: Schedules deferred main-actor flush work.
    ///   - onDrainBoundExceeded: Called with the still-pending payload when a
    ///     flush hits ``maxCoalescedDeliveries`` and defers to another turn.
    ///   - onCircuitBreakerTripped: Called with the retained pending payload when
    ///     a non-converging cycle reaches ``maxConsecutiveBoundedFlushes``.
    ///   - deliver: Delivers one pending payload.
    public init(
        maxCoalescedDeliveries: Int = 8,
        maxConsecutiveBoundedFlushes: Int = 4,
        maxConsecutiveCircuitDeliveries: Int? = nil,
        maxCircuitBreakerRecoveryDeliveries: Int? = nil,
        belongsToSameCircuit: @escaping @MainActor @Sendable (Payload, Payload) -> Bool = { _, _ in false },
        schedule: @escaping @MainActor @Sendable (@escaping @MainActor @Sendable () -> Void) -> Void,
        onDrainBoundExceeded: @escaping @MainActor @Sendable (Payload) -> Void = { _ in },
        onCircuitBreakerTripped: @escaping @MainActor @Sendable (Payload) -> Void = { _ in },
        deliver: @escaping @MainActor @Sendable (Payload) -> Void
    ) {
        let coalescedDeliveryLimit = max(1, maxCoalescedDeliveries)
        let boundedFlushLimit = max(1, maxConsecutiveBoundedFlushes)
        let defaultCircuitDeliveryLimit: Int
        if coalescedDeliveryLimit > Int.max / boundedFlushLimit {
            defaultCircuitDeliveryLimit = Int.max
        } else {
            defaultCircuitDeliveryLimit = coalescedDeliveryLimit * boundedFlushLimit
        }

        self.maxCoalescedDeliveries = coalescedDeliveryLimit
        self.maxConsecutiveBoundedFlushes = boundedFlushLimit
        self.maxConsecutiveCircuitDeliveries = max(1, maxConsecutiveCircuitDeliveries ?? defaultCircuitDeliveryLimit)
        self.maxCircuitBreakerRecoveryDeliveries = max(
            0,
            maxCircuitBreakerRecoveryDeliveries ?? coalescedDeliveryLimit
        )
        self.belongsToSameCircuit = belongsToSameCircuit
        self.schedule = schedule
        self.onDrainBoundExceeded = onDrainBoundExceeded
        self.onCircuitBreakerTripped = onCircuitBreakerTripped
        self.deliver = deliver
    }

    /// Records a payload for asynchronous, coalesced delivery.
    ///
    /// This method never delivers synchronously. If delivery is already in
    /// progress, the payload is recorded for the active drain loop instead of
    /// recursively scheduling more work. If the circuit breaker is open, payloads
    /// in the same circuit are allowed only through the bounded recovery budget;
    /// payloads from a different circuit close the breaker and schedule normally.
    public func emit(_ payload: Payload) {
        let isSameBreakerCircuit = isSameCircuit(as: circuitBreakerReference, payload)
        pending = payload
        if isDelivering { return }
        if circuitBreakerOpen {
            guard isSameBreakerCircuit else {
                closeCircuitBreakerForExternalPayload()
                scheduleImmediateFlush()
                return
            }
            scheduleCircuitBreakerRecoveryIfPossible()
            return
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
                    tripCircuitBreaker(with: next)
                } else {
                    pending = next
                }
                break
            }
            if shouldTripForConsecutiveCircuitDelivery(next) {
                pending = next
                hitCircuitBreaker = true
                tripCircuitBreaker(with: next)
                break
            }
            deliver(next)
            recordCircuitDelivery(next)
        }

        isDelivering = false
        if !hitDeliveryBound {
            consecutiveBoundedFlushes = 0
        }
        if pending != nil {
            if hitCircuitBreaker {
                scheduleCircuitBreakerRecoveryIfPossible()
            } else {
                scheduleImmediateFlush()
            }
        }
    }

    private func flushCircuitBreakerRecovery() {
        guard let next = pending else {
            return
        }
        guard circuitBreakerRecoveryDeliveriesRemaining > 0 else {
            return
        }
        pending = nil
        circuitBreakerRecoveryDeliveriesRemaining -= 1
        isDelivering = true
        deliver(next)
        recordCircuitDelivery(next)
        isDelivering = false
        consecutiveBoundedFlushes = 0
        guard let remaining = pending else { return }
        if isSameCircuit(as: circuitBreakerReference, remaining) {
            scheduleCircuitBreakerRecoveryIfPossible()
        } else {
            closeCircuitBreakerForExternalPayload()
            scheduleImmediateFlush()
        }
    }

    private func scheduleImmediateFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        schedule { @Sendable [weak self] in
            self?.flush()
        }
    }

    private func scheduleCircuitBreakerRecoveryIfPossible() {
        guard circuitBreakerRecoveryDeliveriesRemaining > 0 else {
            pending = nil
            return
        }
        scheduleImmediateFlush()
    }

    private func tripCircuitBreaker(with payload: Payload) {
        circuitBreakerOpen = true
        circuitBreakerReference = payload
        circuitBreakerRecoveryDeliveriesRemaining = maxCircuitBreakerRecoveryDeliveries
        consecutiveBoundedFlushes = 0
        onCircuitBreakerTripped(payload)
    }

    private func closeCircuitBreakerForExternalPayload() {
        circuitBreakerOpen = false
        circuitBreakerReference = nil
        circuitBreakerRecoveryDeliveriesRemaining = 0
        consecutiveBoundedFlushes = 0
        resetCircuitDeliveryTracking()
    }

    private func shouldTripForConsecutiveCircuitDelivery(_ payload: Payload) -> Bool {
        guard let reference = circuitDeliveryReference,
              belongsToSameCircuit(reference, payload) else {
            return false
        }
        return consecutiveCircuitDeliveries >= maxConsecutiveCircuitDeliveries
    }

    private func recordCircuitDelivery(_ payload: Payload) {
        if isSameCircuit(as: circuitDeliveryReference, payload) {
            consecutiveCircuitDeliveries += 1
        } else {
            circuitDeliveryReference = payload
            consecutiveCircuitDeliveries = 1
        }
    }

    private func resetCircuitDeliveryTracking() {
        circuitDeliveryReference = nil
        consecutiveCircuitDeliveries = 0
    }

    private func isSameCircuit(as reference: Payload?, _ payload: Payload) -> Bool {
        guard let reference else { return false }
        return belongsToSameCircuit(reference, payload)
    }
}
