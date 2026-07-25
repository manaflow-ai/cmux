import Foundation
import OSLog

nonisolated private let agentHookDeliveryQueueLogger = Logger(
    subsystem: "com.cmuxterm.app",
    category: "AgentHookDelivery"
)

/// Owns ordered, bounded delivery lanes for admitted non-decision hooks.
actor AgentHookDeliveryQueue {
    typealias Delivery = @Sendable (AgentHookDeliveryEvent) async -> Void

    private enum AdmissionClass: Equatable, Sendable {
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

        var preservesLatestLifecycleState: Bool {
            guard case .event(let event) = self else { return false }
            return [
                "session-start",
                "stop",
                "session-end",
                "session-finalize",
            ].contains(event.subcommand)
        }
    }

    private struct AdmissionRecord: Sendable {
        let item: PendingItem
        let admissionClass: AdmissionClass
    }

    nonisolated private let admissionSignalContinuation: AsyncStream<Void>.Continuation
    // Synchronous socket handlers cannot await actor admission. This lock guards
    // only the fixed-capacity ingress records paired with admission signals;
    // delivery lanes and all ongoing execution state remain actor-isolated.
    nonisolated private let admissionPublicationLock = NSLock()
    // Access is serialized by `admissionPublicationLock`; the array never grows
    // beyond the configured ingress capacities.
    nonisolated(unsafe) private var admissionRecords: [AdmissionRecord] = []
    nonisolated private let maximumLifecycleIngressEvents: Int
    nonisolated private let maximumToolIngressEvents: Int
    nonisolated private let maximumBarrierIngressEvents: Int
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
        let lifecycleIngressCapacity = maximumIngressEvents - toolIngressCapacity
        let admissionSignalPair = AsyncStream.makeStream(
            of: Void.self,
            bufferingPolicy: .bufferingOldest(
                maximumIngressEvents + maximumBarrierIngressEvents
            )
        )
        let capacityPair = AsyncStream.makeStream(
            of: Void.self,
            bufferingPolicy: .bufferingOldest(maximumResidentEvents)
        )
        admissionSignalContinuation = admissionSignalPair.continuation
        maximumLifecycleIngressEvents = lifecycleIngressCapacity
        maximumToolIngressEvents = toolIngressCapacity
        self.maximumBarrierIngressEvents = maximumBarrierIngressEvents
        capacityContinuation = capacityPair.continuation
        self.delivery = delivery
        self.maximumConcurrentDeliveries = maximumConcurrentDeliveries

        for _ in 0..<maximumResidentEvents {
            capacityPair.continuation.yield(())
        }

        Task {
            [
                weak self,
                admissionSignalStream = admissionSignalPair.stream,
                capacityStream = capacityPair.stream,
                capacityContinuation = capacityPair.continuation,
            ] in
            var admissionSignalIterator = admissionSignalStream.makeAsyncIterator()
            for await _ in capacityStream {
                guard await admissionSignalIterator.next() != nil,
                      let self else { return }
                // Reserve actor capacity before removing an item from bounded ingress.
                guard let item = self.takeNextPublishedItem() else {
                    assertionFailure("Agent hook admission signal had no item")
                    capacityContinuation.yield(())
                    continue
                }
                await self.accept(item)
            }
        }
    }

    deinit {
        admissionSignalContinuation.finish()
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

        let capacity: Int
        switch admissionClass {
        case .lifecycle:
            capacity = maximumLifecycleIngressEvents
        case .bestEffortTool:
            capacity = maximumToolIngressEvents
        case .barrier:
            capacity = maximumBarrierIngressEvents
        }
        let classCount = admissionRecords.lazy.filter {
            $0.admissionClass == admissionClass
        }.count
        if classCount >= capacity {
            guard admissionClass == .lifecycle,
                  item.preservesLatestLifecycleState,
                  let replacementIndex = lifecycleReplacementIndex(for: item)
            else {
                agentHookDeliveryQueueLogger.error(
                    "Hook admission dropped \(droppedDescription, privacy: .public)"
                )
                return false
            }
            let replaced = admissionRecords.remove(at: replacementIndex)
            admissionRecords.append(AdmissionRecord(
                item: item,
                admissionClass: admissionClass
            ))
            agentHookDeliveryQueueLogger.info(
                "Hook admission replaced stale \(String(describing: replaced.item), privacy: .private)"
            )
            return true
        }

        admissionRecords.append(AdmissionRecord(
            item: item,
            admissionClass: admissionClass
        ))
        switch admissionSignalContinuation.yield(()) {
        case .enqueued:
            return true
        case .dropped:
            admissionRecords.removeLast()
            assertionFailure("Agent hook admission signal overflowed")
            agentHookDeliveryQueueLogger.error(
                "Hook admission dropped \(droppedDescription, privacy: .public)"
            )
            return false
        case .terminated:
            admissionRecords.removeLast()
            return false
        @unknown default:
            admissionRecords.removeLast()
            return false
        }
    }

    private nonisolated func lifecycleReplacementIndex(
        for item: PendingItem
    ) -> Int? {
        let lifecycleIndices = admissionRecords.indices.filter {
            admissionRecords[$0].admissionClass == .lifecycle
        }
        return lifecycleIndices.first {
            admissionRecords[$0].item.orderingKey == item.orderingKey
        } ?? lifecycleIndices.first {
            !admissionRecords[$0].item.preservesLatestLifecycleState
        } ?? lifecycleIndices.first
    }

    private nonisolated func takeNextPublishedItem() -> PendingItem? {
        admissionPublicationLock.lock()
        defer { admissionPublicationLock.unlock() }
        guard !admissionRecords.isEmpty else { return nil }
        return admissionRecords.removeFirst().item
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
