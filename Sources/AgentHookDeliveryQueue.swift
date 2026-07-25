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
        case barrier
    }

    private enum PendingItem: Sendable {
        case event(AgentHookDeliveryEvent)
        case barrier(orderingKey: String, signal: DispatchSemaphore)

        var orderingKey: String {
            switch self {
            case .event(let event):
                return event.orderingKey
            case .barrier(let orderingKey, _):
                return orderingKey
            }
        }

        var isBarrier: Bool {
            if case .barrier = self { return true }
            return false
        }
    }

    nonisolated private let lifecycleAdmissionContinuation: AsyncStream<PendingItem>.Continuation
    nonisolated private let toolAdmissionContinuation: AsyncStream<PendingItem>.Continuation
    nonisolated private let barrierAdmissionContinuation: AsyncStream<PendingItem>.Continuation
    nonisolated private let admissionOrderContinuation: AsyncStream<AdmissionClass>.Continuation
    // A synchronous hook can publish from any socket worker. This lock only
    // keeps the item-stream yield adjacent to its order-token yield; actor-owned
    // queue state remains isolated below.
    nonisolated private let admissionPublicationLock = NSLock()
    private let capacityContinuation: AsyncStream<Void>.Continuation
    private let delivery: Delivery
    private let maximumConcurrentDeliveries: Int
    private var pendingByOrderingKey: [String: [PendingItem]] = [:]
    private var readyOrderingKeys: [String] = []
    private var activeOrderingKeys: Set<String> = []

    init(process: AgentHookDeliveryProcess = AgentHookDeliveryProcess()) {
        self.init { event in
            await process.deliver(event)
        }
    }

    /// Builds a queue whose defaults retain at most twenty bounded items:
    /// eight actor-resident items, eight event-ingress items, and four barriers.
    /// Event ingress reserves one replaceable slot for high-volume tool and shell
    /// telemetry; lifecycle, needs-input, and notification events use the rest.
    /// The event validator's payload and environment limits therefore also
    /// place a finite byte bound on the complete accepted backlog.
    init(
        maximumConcurrentDeliveries: Int = 4,
        maximumResidentEvents: Int = 8,
        maximumIngressEvents: Int = 8,
        maximumBarrierIngressEvents: Int = 4,
        delivery: @escaping Delivery
    ) {
        precondition(maximumConcurrentDeliveries > 0)
        precondition(maximumResidentEvents >= maximumConcurrentDeliveries)
        precondition(maximumIngressEvents >= 2)
        precondition(maximumBarrierIngressEvents > 0)

        let toolIngressCapacity = 1
        let lifecycleAdmissionPair = AsyncStream.makeStream(
            of: PendingItem.self,
            bufferingPolicy: .bufferingOldest(maximumIngressEvents - toolIngressCapacity)
        )
        let toolAdmissionPair = AsyncStream.makeStream(
            of: PendingItem.self,
            bufferingPolicy: .bufferingOldest(toolIngressCapacity)
        )
        let barrierAdmissionPair = AsyncStream.makeStream(
            of: PendingItem.self,
            bufferingPolicy: .bufferingOldest(maximumBarrierIngressEvents)
        )
        let admissionOrderPair = AsyncStream.makeStream(
            of: AdmissionClass.self,
            bufferingPolicy: .bufferingOldest(
                maximumIngressEvents + maximumBarrierIngressEvents
            )
        )
        let capacityPair = AsyncStream.makeStream(
            of: Void.self,
            bufferingPolicy: .bufferingOldest(maximumResidentEvents)
        )
        lifecycleAdmissionContinuation = lifecycleAdmissionPair.continuation
        toolAdmissionContinuation = toolAdmissionPair.continuation
        barrierAdmissionContinuation = barrierAdmissionPair.continuation
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
                barrierAdmissionStream = barrierAdmissionPair.stream,
                admissionOrderStream = admissionOrderPair.stream,
                capacityStream = capacityPair.stream,
            ] in
            var lifecycleAdmissionIterator = lifecycleAdmissionStream.makeAsyncIterator()
            var toolAdmissionIterator = toolAdmissionStream.makeAsyncIterator()
            var barrierAdmissionIterator = barrierAdmissionStream.makeAsyncIterator()
            var admissionOrderIterator = admissionOrderStream.makeAsyncIterator()
            for await _ in capacityStream {
                guard let admissionClass = await admissionOrderIterator.next() else { return }
                let item: PendingItem?
                switch admissionClass {
                case .lifecycle:
                    item = await lifecycleAdmissionIterator.next()
                case .bestEffortTool:
                    item = await toolAdmissionIterator.next()
                case .barrier:
                    item = await barrierAdmissionIterator.next()
                }
                // Reserve actor capacity before removing an item from bounded ingress.
                guard let item, let self else { return }
                await self.accept(item)
            }
        }
    }

    deinit {
        lifecycleAdmissionContinuation.finish()
        toolAdmissionContinuation.finish()
        barrierAdmissionContinuation.finish()
        admissionOrderContinuation.finish()
        capacityContinuation.finish()
    }

    /// Synchronously transfers ownership to bounded ingress. The socket can
    /// acknowledge immediately after this returns true; false fails open.
    nonisolated func enqueue(_ event: AgentHookDeliveryEvent) -> Bool {
        publish(
            .event(event),
            admissionClass: event.isBestEffortTelemetry ? .bestEffortTool : .lifecycle,
            droppedDescription: "agent=\(event.agent) subcommand=\(event.subcommand)"
        )
    }

    /// Waits until every earlier item in one delivery lane has completed.
    /// The signal occupies bounded ingress/resident capacity but never a global
    /// child-process delivery slot. A timeout leaves the eventual signal inert.
    nonisolated func waitForPriorDeliveries(
        orderingKey: String,
        timeout: TimeInterval
    ) -> Bool {
        guard timeout > 0, timeout.isFinite else { return false }
        let signal = DispatchSemaphore(value: 0)
        guard publish(
            .barrier(orderingKey: orderingKey, signal: signal),
            admissionClass: .barrier,
            droppedDescription: "barrier"
        ) else {
            return false
        }
        return signal.wait(timeout: .now() + timeout) == .success
    }

    private nonisolated func publish(
        _ item: PendingItem,
        admissionClass: AdmissionClass,
        droppedDescription: String
    ) -> Bool {
        admissionPublicationLock.lock()
        defer { admissionPublicationLock.unlock() }

        let result: AsyncStream<PendingItem>.Continuation.YieldResult
        switch admissionClass {
        case .lifecycle:
            result = lifecycleAdmissionContinuation.yield(item)
        case .bestEffortTool:
            result = toolAdmissionContinuation.yield(item)
        case .barrier:
            result = barrierAdmissionContinuation.yield(item)
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
                "Hook admission dropped \(droppedDescription, privacy: .public)"
            )
            return false
        case .terminated:
            return false
        @unknown default:
            return false
        }
    }

    private func accept(_ item: PendingItem) {
        let orderingKey = item.orderingKey
        pendingByOrderingKey[orderingKey, default: []].append(item)
        if !activeOrderingKeys.contains(orderingKey), !readyOrderingKeys.contains(orderingKey) {
            readyOrderingKeys.append(orderingKey)
        }
        startReadyDeliveries()
    }

    private func startReadyDeliveries() {
        while let readyIndex = nextReadyOrderingKeyIndex() {
            let orderingKey = readyOrderingKeys.remove(at: readyIndex)
            guard let item = takeNextItem(orderingKey: orderingKey) else { continue }
            switch item {
            case .barrier(_, let signal):
                signal.signal()
                capacityContinuation.yield(())
                if pendingByOrderingKey[orderingKey]?.isEmpty == false {
                    readyOrderingKeys.append(orderingKey)
                }
            case .event(let event):
                activeOrderingKeys.insert(orderingKey)
                let delivery = self.delivery
                Task { [weak self] in
                    await delivery(event)
                    await self?.deliveryFinished(orderingKey: orderingKey)
                }
            }
        }
    }

    private func nextReadyOrderingKeyIndex() -> Int? {
        guard !readyOrderingKeys.isEmpty else { return nil }
        if activeOrderingKeys.count < maximumConcurrentDeliveries {
            return readyOrderingKeys.startIndex
        }
        return readyOrderingKeys.firstIndex { orderingKey in
            pendingByOrderingKey[orderingKey]?.first?.isBarrier == true
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

    private func takeNextItem(orderingKey: String) -> PendingItem? {
        guard var pending = pendingByOrderingKey[orderingKey], !pending.isEmpty else {
            pendingByOrderingKey.removeValue(forKey: orderingKey)
            return nil
        }
        let item = pending.removeFirst()
        if pending.isEmpty {
            pendingByOrderingKey.removeValue(forKey: orderingKey)
        } else {
            pendingByOrderingKey[orderingKey] = pending
        }
        return item
    }
}
