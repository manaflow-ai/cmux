import Foundation

/// Owns ordered, bounded delivery lanes for admitted non-decision hooks.
actor AgentHookDeliveryQueue {
    typealias Delivery = @Sendable (AgentHookDeliveryEvent) async -> Void

    nonisolated private let admissionContinuation: AsyncStream<AgentHookDeliveryEvent>.Continuation
    private let capacityContinuation: AsyncStream<Void>.Continuation
    private let delivery: Delivery
    private let maximumConcurrentDeliveries: Int
    private var pendingByOrderingKey: [String: [AgentHookDeliveryEvent]] = [:]
    private var readyOrderingKeys: [String] = []
    private var activeOrderingKeys: Set<String> = []

    init(process: AgentHookDeliveryProcess = AgentHookDeliveryProcess()) {
        self.init { event in
            await process.deliver(event)
        }
    }

    /// Builds a queue whose defaults retain at most eight validated events:
    /// four actor-resident events and four events in synchronous ingress.
    /// The event validator's payload and environment limits therefore also
    /// place a finite byte bound on the complete accepted backlog.
    init(
        maximumConcurrentDeliveries: Int = 4,
        maximumResidentEvents: Int = 4,
        maximumIngressEvents: Int = 4,
        delivery: @escaping Delivery
    ) {
        precondition(maximumConcurrentDeliveries > 0)
        precondition(maximumResidentEvents >= maximumConcurrentDeliveries)
        precondition(maximumIngressEvents > 0)

        let admissionPair = AsyncStream.makeStream(
            of: AgentHookDeliveryEvent.self,
            bufferingPolicy: .bufferingOldest(maximumIngressEvents)
        )
        let capacityPair = AsyncStream.makeStream(
            of: Void.self,
            bufferingPolicy: .bufferingOldest(maximumResidentEvents)
        )
        admissionContinuation = admissionPair.continuation
        capacityContinuation = capacityPair.continuation
        self.delivery = delivery
        self.maximumConcurrentDeliveries = maximumConcurrentDeliveries

        for _ in 0..<maximumResidentEvents {
            capacityPair.continuation.yield(())
        }

        Task {
            [weak self, admissionStream = admissionPair.stream, capacityStream = capacityPair.stream] in
            var admissionIterator = admissionStream.makeAsyncIterator()
            for await _ in capacityStream {
                // Reserve actor capacity before removing an event from bounded ingress.
                guard let event = await admissionIterator.next(), let self else { return }
                await self.accept(event)
            }
        }
    }

    deinit {
        admissionContinuation.finish()
        capacityContinuation.finish()
    }

    /// Synchronously transfers ownership to bounded ingress. The socket can
    /// acknowledge immediately after this returns true; false fails open.
    nonisolated func enqueue(_ event: AgentHookDeliveryEvent) -> Bool {
        switch admissionContinuation.yield(event) {
        case .enqueued:
            return true
        case .dropped, .terminated:
            return false
        @unknown default:
            return false
        }
    }

    private func accept(_ event: AgentHookDeliveryEvent) {
        let orderingKey = event.orderingKey
        pendingByOrderingKey[orderingKey, default: []].append(event)
        if !activeOrderingKeys.contains(orderingKey), !readyOrderingKeys.contains(orderingKey) {
            readyOrderingKeys.append(orderingKey)
        }
        startReadyDeliveries()
    }

    private func startReadyDeliveries() {
        while activeOrderingKeys.count < maximumConcurrentDeliveries,
              let orderingKey = readyOrderingKeys.first {
            readyOrderingKeys.removeFirst()
            guard let event = takeNextEvent(orderingKey: orderingKey) else { continue }
            activeOrderingKeys.insert(orderingKey)
            let delivery = self.delivery
            Task { [weak self] in
                await delivery(event)
                await self?.deliveryFinished(orderingKey: orderingKey)
            }
        }
    }

    private func deliveryFinished(orderingKey: String) {
        guard activeOrderingKeys.remove(orderingKey) != nil else { return }
        // Return exactly the resident-capacity permit reserved before acceptance.
        capacityContinuation.yield(())
        if pendingByOrderingKey[orderingKey]?.isEmpty == false {
            readyOrderingKeys.append(orderingKey)
        }
        startReadyDeliveries()
    }

    private func takeNextEvent(orderingKey: String) -> AgentHookDeliveryEvent? {
        guard var pending = pendingByOrderingKey[orderingKey], !pending.isEmpty else {
            pendingByOrderingKey.removeValue(forKey: orderingKey)
            return nil
        }
        let event = pending.removeFirst()
        if pending.isEmpty {
            pendingByOrderingKey.removeValue(forKey: orderingKey)
        } else {
            pendingByOrderingKey[orderingKey] = pending
        }
        return event
    }
}
