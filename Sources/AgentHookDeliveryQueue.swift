import Foundation
import OSLog

nonisolated private let agentHookDeliveryQueueLogger = Logger(
    subsystem: "com.cmuxterm.app",
    category: "AgentHookDelivery"
)

/// Owns ordered, bounded delivery lanes for admitted non-decision hooks.
actor AgentHookDeliveryQueue {
    typealias Delivery = @Sendable (AgentHookDeliveryEvent) async -> Void

    private enum AdmissionClass: Sendable {
        case lifecycle
        case bestEffortTool
    }

    nonisolated private let lifecycleAdmissionContinuation: AsyncStream<AgentHookDeliveryEvent>.Continuation
    nonisolated private let toolAdmissionContinuation: AsyncStream<AgentHookDeliveryEvent>.Continuation
    nonisolated private let admissionOrderContinuation: AsyncStream<AdmissionClass>.Continuation
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

    /// Builds a queue whose defaults retain at most sixteen compact validated
    /// events: eight actor-resident events and eight events in synchronous ingress.
    /// Ingress reserves one slot for best-effort Codex PostToolUse telemetry;
    /// lifecycle, needs-input, and notification events use the remaining slots.
    /// The event validator's payload and environment limits therefore also
    /// place a finite byte bound on the complete accepted backlog.
    init(
        maximumConcurrentDeliveries: Int = 4,
        maximumResidentEvents: Int = 8,
        maximumIngressEvents: Int = 8,
        delivery: @escaping Delivery
    ) {
        precondition(maximumConcurrentDeliveries > 0)
        precondition(maximumResidentEvents >= maximumConcurrentDeliveries)
        precondition(maximumIngressEvents >= 2)

        let toolIngressCapacity = 1
        let lifecycleAdmissionPair = AsyncStream.makeStream(
            of: AgentHookDeliveryEvent.self,
            bufferingPolicy: .bufferingOldest(maximumIngressEvents - toolIngressCapacity)
        )
        let toolAdmissionPair = AsyncStream.makeStream(
            of: AgentHookDeliveryEvent.self,
            bufferingPolicy: .bufferingOldest(toolIngressCapacity)
        )
        let admissionOrderPair = AsyncStream.makeStream(
            of: AdmissionClass.self,
            bufferingPolicy: .bufferingOldest(maximumIngressEvents)
        )
        let capacityPair = AsyncStream.makeStream(
            of: Void.self,
            bufferingPolicy: .bufferingOldest(maximumResidentEvents)
        )
        lifecycleAdmissionContinuation = lifecycleAdmissionPair.continuation
        toolAdmissionContinuation = toolAdmissionPair.continuation
        admissionOrderContinuation = admissionOrderPair.continuation
        capacityContinuation = capacityPair.continuation
        self.delivery = delivery
        self.maximumConcurrentDeliveries = maximumConcurrentDeliveries

        for _ in 0..<maximumResidentEvents {
            capacityPair.continuation.yield(())
        }

        Task {
            [
                weak self,
                lifecycleAdmissionStream = lifecycleAdmissionPair.stream,
                toolAdmissionStream = toolAdmissionPair.stream,
                admissionOrderStream = admissionOrderPair.stream,
                capacityStream = capacityPair.stream,
            ] in
            var lifecycleAdmissionIterator = lifecycleAdmissionStream.makeAsyncIterator()
            var toolAdmissionIterator = toolAdmissionStream.makeAsyncIterator()
            var admissionOrderIterator = admissionOrderStream.makeAsyncIterator()
            for await _ in capacityStream {
                guard let admissionClass = await admissionOrderIterator.next() else { return }
                let event: AgentHookDeliveryEvent?
                switch admissionClass {
                case .lifecycle:
                    event = await lifecycleAdmissionIterator.next()
                case .bestEffortTool:
                    event = await toolAdmissionIterator.next()
                }
                // Reserve actor capacity before removing an event from bounded ingress.
                guard let event, let self else { return }
                await self.accept(event)
            }
        }
    }

    deinit {
        lifecycleAdmissionContinuation.finish()
        toolAdmissionContinuation.finish()
        admissionOrderContinuation.finish()
        capacityContinuation.finish()
    }

    /// Synchronously transfers ownership to bounded ingress. The socket can
    /// acknowledge immediately after this returns true; false fails open.
    nonisolated func enqueue(_ event: AgentHookDeliveryEvent) -> Bool {
        let admissionClass: AdmissionClass
        let result: AsyncStream<AgentHookDeliveryEvent>.Continuation.YieldResult
        if event.isBestEffortTelemetry {
            admissionClass = .bestEffortTool
            result = toolAdmissionContinuation.yield(event)
        } else {
            admissionClass = .lifecycle
            result = lifecycleAdmissionContinuation.yield(event)
        }
        switch result {
        case .enqueued:
            switch admissionOrderContinuation.yield(admissionClass) {
            case .enqueued:
                return true
            case .terminated:
                return false
            case .dropped:
                // Class capacities sum to order capacity, and the consumer removes
                // each order token before its event, so a live queue cannot overflow here.
                assertionFailure("Agent hook admission order overflowed")
                return false
            @unknown default:
                return false
            }
        case .dropped:
            agentHookDeliveryQueueLogger.error(
                "Hook admission dropped agent=\(event.agent, privacy: .public) subcommand=\(event.subcommand, privacy: .public)"
            )
            return false
        case .terminated:
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
