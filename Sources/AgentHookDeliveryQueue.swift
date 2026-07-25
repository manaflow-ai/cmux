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
        case terminalLifecycle
        case bestEffortTool
        case barrier
    }

    private enum PendingItem: Sendable {
        case event(AgentHookDeliveryEvent)
        case barrier(orderingKey: String, signal: DispatchSemaphore)
        case discarded(orderingKey: String)

        var orderingKey: String {
            switch self {
            case .event(let event):
                return event.orderingKey
            case .barrier(let orderingKey, _):
                return orderingKey
            case .discarded(let orderingKey):
                return orderingKey
            }
        }

        func canBeReplaced(by newerItem: Self) -> Bool {
            guard case .event(let earlierEvent) = self,
                  case .event(let newerEvent) = newerItem else {
                return false
            }
            return newerEvent.canReplaceBufferedLifecycleState(earlierEvent)
        }
    }

    private struct AdmissionRecord: Sendable {
        let item: PendingItem
        let admissionClass: AdmissionClass

        var orderingKey: String {
            item.orderingKey
        }
    }

    nonisolated private let admissionSignalContinuation: AsyncStream<Void>.Continuation
    // Synchronous socket handlers cannot await actor admission. This lock guards
    // only the fixed-capacity ingress records paired with admission signals;
    // delivery lanes and all ongoing execution state remain actor-isolated.
    nonisolated private let admissionPublicationLock = NSLock()
    // Access is serialized by `admissionPublicationLock`; the array never grows
    // beyond the configured ingress capacities.
    nonisolated(unsafe) private var admissionRecords: [AdmissionRecord] = []
    // Best-effort telemetry remains bounded after it leaves ingress. Limiting
    // one event per lane and reserving a delivery slot prevents tool bursts
    // from monopolizing resident capacity ahead of lifecycle/barrier work.
    nonisolated(unsafe) private var outstandingBestEffortOrderingKeys: Set<String> = []
    nonisolated private let maximumLifecycleIngressEvents: Int
    nonisolated private let maximumTerminalIngressEvents: Int
    nonisolated private let maximumToolIngressEvents: Int
    nonisolated private let maximumBarrierIngressEvents: Int
    nonisolated private let maximumOutstandingBestEffortEvents: Int
    private let capacityContinuation: AsyncStream<Void>.Continuation
    private let delivery: Delivery
    private let maximumConcurrentDeliveries: Int
    private let maximumOrdinaryConcurrentDeliveries: Int
    private let maximumBestEffortConcurrentDeliveries: Int
    private var pendingByOrderingKey: [String: [AdmissionRecord]] = [:]
    private var readyOrderingKeys: [String] = []
    private var activeAdmissionClassByOrderingKey: [String: AdmissionClass] = [:]

    init(process: AgentHookDeliveryProcess = AgentHookDeliveryProcess()) {
        self.init { event in
            await process.deliver(event)
        }
    }

    /// Builds a queue whose defaults retain at most twenty-four bounded items:
    /// eight actor-resident items, eight general event-ingress items, four
    /// terminal lifecycle items, and four barriers. General event ingress
    /// reserves one replaceable slot for high-volume tool and shell telemetry;
    /// actor execution reserves one slot for terminal transitions and one
    /// ordinary slot ahead of best-effort telemetry. Terminal transitions
    /// cannot be displaced by notifications or finalizers.
    /// The event validator's payload and environment limits therefore also
    /// place a finite byte bound on the complete accepted backlog.
    init(
        maximumConcurrentDeliveries: Int = 4,
        maximumResidentEvents: Int = 8,
        maximumIngressEvents: Int = 8,
        maximumTerminalIngressEvents: Int = 4,
        maximumBarrierIngressEvents: Int = 4,
        delivery: @escaping Delivery
    ) {
        precondition(maximumConcurrentDeliveries > 0)
        precondition(maximumResidentEvents >= maximumConcurrentDeliveries)
        precondition(maximumIngressEvents >= 2)
        precondition(maximumTerminalIngressEvents > 0)
        precondition(maximumBarrierIngressEvents > 0)

        let toolIngressCapacity = 1
        let lifecycleIngressCapacity = maximumIngressEvents - toolIngressCapacity
        let admissionSignalPair = AsyncStream.makeStream(
            of: Void.self,
            bufferingPolicy: .bufferingOldest(
                maximumIngressEvents
                    + maximumTerminalIngressEvents
                    + maximumBarrierIngressEvents
            )
        )
        let capacityPair = AsyncStream.makeStream(
            of: Void.self,
            bufferingPolicy: .bufferingOldest(maximumResidentEvents)
        )
        admissionSignalContinuation = admissionSignalPair.continuation
        maximumLifecycleIngressEvents = lifecycleIngressCapacity
        self.maximumTerminalIngressEvents = maximumTerminalIngressEvents
        maximumToolIngressEvents = toolIngressCapacity
        self.maximumBarrierIngressEvents = maximumBarrierIngressEvents
        maximumOutstandingBestEffortEvents = max(1, maximumConcurrentDeliveries - 1)
        capacityContinuation = capacityPair.continuation
        self.delivery = delivery
        self.maximumConcurrentDeliveries = maximumConcurrentDeliveries
        maximumOrdinaryConcurrentDeliveries = max(
            1,
            maximumConcurrentDeliveries - 1
        )
        maximumBestEffortConcurrentDeliveries = max(
            1,
            maximumOrdinaryConcurrentDeliveries - 1
        )

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
        let admittedEvent = event.admittedToQueue(at: ContinuousClock().now)
        let admissionClass: AdmissionClass
        if admittedEvent.isBestEffortTelemetry {
            admissionClass = .bestEffortTool
        } else if admittedEvent.requiresReservedTerminalAdmission {
            admissionClass = .terminalLifecycle
        } else {
            admissionClass = .lifecycle
        }
        return publish(
            .event(admittedEvent),
            admissionClass: admissionClass,
            droppedDescription: "agent=\(admittedEvent.agent) subcommand=\(admittedEvent.subcommand)"
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
        case .terminalLifecycle:
            capacity = maximumTerminalIngressEvents
        case .bestEffortTool:
            capacity = maximumToolIngressEvents
        case .barrier:
            capacity = maximumBarrierIngressEvents
        }
        let classCount = admissionRecords.lazy.filter {
            $0.admissionClass == admissionClass
        }.count
        if admissionClass == .terminalLifecycle,
           replacePublishedLifecycleState(
               with: item,
               terminalClassCount: classCount,
               terminalCapacity: capacity
           ) {
            return true
        }
        if classCount >= capacity {
            guard admissionClass == .lifecycle,
                  let replacementIndex = lifecycleReplacementIndex(
                    replacedBy: item,
                    admissionClass: admissionClass
                  )
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

        if admissionClass == .bestEffortTool {
            let orderingKey = item.orderingKey
            guard !outstandingBestEffortOrderingKeys.contains(orderingKey),
                  outstandingBestEffortOrderingKeys.count
                    < maximumOutstandingBestEffortEvents
            else {
                agentHookDeliveryQueueLogger.error(
                    "Hook admission dropped \(droppedDescription, privacy: .public)"
                )
                return false
            }
            outstandingBestEffortOrderingKeys.insert(orderingKey)
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
            rollbackOutstandingBestEffortReservation(
                admissionClass: admissionClass,
                orderingKey: item.orderingKey
            )
            assertionFailure("Agent hook admission signal overflowed")
            agentHookDeliveryQueueLogger.error(
                "Hook admission dropped \(droppedDescription, privacy: .public)"
            )
            return false
        case .terminated:
            admissionRecords.removeLast()
            rollbackOutstandingBestEffortReservation(
                admissionClass: admissionClass,
                orderingKey: item.orderingKey
            )
            return false
        @unknown default:
            admissionRecords.removeLast()
            rollbackOutstandingBestEffortReservation(
                admissionClass: admissionClass,
                orderingKey: item.orderingKey
            )
            return false
        }
    }

    /// Called only while `admissionPublicationLock` is held. Every superseded
    /// ingress record keeps its signal as a bounded discard marker, while one
    /// signal slot is reused for the newer terminal event. Appending the
    /// terminal record after all older ingress preserves intervening side
    /// effects such as notifications and finalizers.
    private nonisolated func replacePublishedLifecycleState(
        with terminalItem: PendingItem,
        terminalClassCount: Int,
        terminalCapacity: Int
    ) -> Bool {
        let replaceableIndices = admissionRecords.indices.filter {
            admissionRecords[$0].item.canBeReplaced(by: terminalItem)
        }
        guard !replaceableIndices.isEmpty else { return false }

        let replaceableTerminalIndex = replaceableIndices.last {
            admissionRecords[$0].admissionClass == .terminalLifecycle
        }
        if terminalClassCount >= terminalCapacity,
           replaceableTerminalIndex == nil {
            return false
        }
        let reusedSignalIndex = replaceableTerminalIndex
            ?? replaceableIndices[replaceableIndices.index(before: replaceableIndices.endIndex)]
        let replaceableIndexSet = Set(replaceableIndices)
        var updatedRecords: [AdmissionRecord] = []
        updatedRecords.reserveCapacity(admissionRecords.count)
        for index in admissionRecords.indices {
            let record = admissionRecords[index]
            guard replaceableIndexSet.contains(index) else {
                updatedRecords.append(record)
                continue
            }
            if index != reusedSignalIndex {
                updatedRecords.append(AdmissionRecord(
                    item: .discarded(orderingKey: record.orderingKey),
                    admissionClass: record.admissionClass
                ))
            }
        }
        updatedRecords.append(AdmissionRecord(
            item: terminalItem,
            admissionClass: .terminalLifecycle
        ))
        admissionRecords = updatedRecords
        agentHookDeliveryQueueLogger.info(
            "Hook admission superseded \(replaceableIndices.count) stale lifecycle record(s)"
        )
        return true
    }

    /// Called only while `admissionPublicationLock` is held.
    private nonisolated func rollbackOutstandingBestEffortReservation(
        admissionClass: AdmissionClass,
        orderingKey: String
    ) {
        guard admissionClass == .bestEffortTool else { return }
        let removed = outstandingBestEffortOrderingKeys.remove(orderingKey)
        assert(removed != nil)
    }

    private nonisolated func lifecycleReplacementIndex(
        replacedBy item: PendingItem,
        admissionClass: AdmissionClass
    ) -> Int? {
        let lifecycleIndices = admissionRecords.indices.filter {
            admissionRecords[$0].admissionClass == admissionClass
        }
        return lifecycleIndices.first {
            admissionRecords[$0].item.canBeReplaced(by: item)
        }
    }

    private nonisolated func releaseOutstandingBestEffortReservation(
        orderingKey: String
    ) {
        admissionPublicationLock.lock()
        let removed = outstandingBestEffortOrderingKeys.remove(orderingKey)
        admissionPublicationLock.unlock()
        assert(removed != nil)
    }

    private nonisolated func takeNextPublishedItem() -> AdmissionRecord? {
        admissionPublicationLock.lock()
        defer { admissionPublicationLock.unlock() }
        guard !admissionRecords.isEmpty else { return nil }
        return admissionRecords.removeFirst()
    }

    private func accept(_ record: AdmissionRecord) {
        if case .discarded = record.item {
            capacityContinuation.yield(())
            return
        }

        let orderingKey = record.orderingKey
        if record.admissionClass == .terminalLifecycle {
            var pending = pendingByOrderingKey[orderingKey] ?? []
            let originalCount = pending.count
            pending.removeAll {
                $0.item.canBeReplaced(by: record.item)
            }
            let removedCount = originalCount - pending.count
            pending.append(record)
            pendingByOrderingKey[orderingKey] = pending
            for _ in 0..<removedCount {
                capacityContinuation.yield(())
            }
        } else {
            pendingByOrderingKey[orderingKey, default: []].append(record)
        }
        if activeAdmissionClassByOrderingKey[orderingKey] == nil,
           !readyOrderingKeys.contains(orderingKey) {
            readyOrderingKeys.append(orderingKey)
        }
        startReadyDeliveries()
    }

    private func startReadyDeliveries() {
        while let readyIndex = nextReadyOrderingKeyIndex() {
            let orderingKey = readyOrderingKeys.remove(at: readyIndex)
            guard let record = takeNextItem(orderingKey: orderingKey) else { continue }
            switch record.item {
            case .barrier(_, let signal):
                signal.signal()
                capacityContinuation.yield(())
                if pendingByOrderingKey[orderingKey]?.isEmpty == false {
                    readyOrderingKeys.append(orderingKey)
                }
            case .event(let event):
                activeAdmissionClassByOrderingKey[orderingKey] =
                    record.admissionClass
                let delivery = self.delivery
                Task { [weak self] in
                    await delivery(event)
                    await self?.deliveryFinished(
                        orderingKey: orderingKey,
                        completedBestEffortTelemetry: event.isBestEffortTelemetry
                    )
                }
            case .discarded:
                assertionFailure("Discarded hook record reached delivery scheduling")
                capacityContinuation.yield(())
            }
        }
    }

    private func nextReadyOrderingKeyIndex() -> Int? {
        guard !readyOrderingKeys.isEmpty else { return nil }
        if let barrierIndex = readyOrderingKeys.firstIndex(where: {
            pendingByOrderingKey[$0]?.first?.admissionClass == .barrier
        }) {
            return barrierIndex
        }
        guard activeAdmissionClassByOrderingKey.count
                < maximumConcurrentDeliveries else {
            return nil
        }
        if let terminalIndex = readyOrderingKeys.firstIndex(where: {
            pendingByOrderingKey[$0]?.first?.admissionClass
                == .terminalLifecycle
        }) {
            return terminalIndex
        }

        let activeOrdinaryCount = activeAdmissionClassByOrderingKey.values.lazy
            .filter { $0 != .terminalLifecycle }
            .count
        guard activeOrdinaryCount < maximumOrdinaryConcurrentDeliveries else {
            return nil
        }
        if let lifecycleIndex = readyOrderingKeys.firstIndex(where: {
            pendingByOrderingKey[$0]?.first?.admissionClass == .lifecycle
        }) {
            return lifecycleIndex
        }

        let activeBestEffortCount = activeAdmissionClassByOrderingKey.values.lazy
            .filter { $0 == .bestEffortTool }
            .count
        guard activeBestEffortCount < maximumBestEffortConcurrentDeliveries else {
            return nil
        }
        return readyOrderingKeys.firstIndex { orderingKey in
            pendingByOrderingKey[orderingKey]?.first?.admissionClass
                == .bestEffortTool
        }
    }

    private func deliveryFinished(
        orderingKey: String,
        completedBestEffortTelemetry: Bool
    ) {
        guard activeAdmissionClassByOrderingKey.removeValue(
            forKey: orderingKey
        ) != nil else {
            return
        }
        if completedBestEffortTelemetry {
            releaseOutstandingBestEffortReservation(orderingKey: orderingKey)
        }
        // Return exactly the resident-capacity permit reserved before acceptance.
        capacityContinuation.yield(())
        if pendingByOrderingKey[orderingKey]?.isEmpty == false {
            readyOrderingKeys.append(orderingKey)
        }
        startReadyDeliveries()
    }

    private func takeNextItem(orderingKey: String) -> AdmissionRecord? {
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
