import Foundation

/// Owns ordered, bounded delivery lanes for admitted non-decision hooks.
actor AgentHookDeliveryQueue {
    typealias Delivery = @Sendable (AgentHookDeliveryEvent) async -> Void

    private enum Admission: Sendable {
        case event(AgentHookDeliveryEvent)
        case barrier(CheckedContinuation<Void, Never>)
    }

    nonisolated private let admissionContinuation: AsyncStream<Admission>.Continuation
    private let admissionTask: Task<Void, Never>
    private let delivery: Delivery
    private var pendingByOrderingKey: [String: [AgentHookDeliveryEvent]] = [:]
    private var drainTasksByOrderingKey: [String: Task<Void, Never>] = [:]
    private var idleBarriers: [CheckedContinuation<Void, Never>] = []

    init(process: AgentHookDeliveryProcess = AgentHookDeliveryProcess()) {
        self.init { event in
            await process.deliver(event)
        }
    }

    init(delivery: @escaping Delivery) {
        let pair = AsyncStream.makeStream(
            of: Admission.self,
            bufferingPolicy: .bufferingOldest(4_096)
        )
        admissionContinuation = pair.continuation
        self.delivery = delivery
        admissionTask = Task { [weak self, stream = pair.stream] in
            for await admission in stream {
                guard let self else { return }
                await self.accept(admission)
            }
        }
    }

    deinit {
        admissionContinuation.finish()
        admissionTask.cancel()
        for task in drainTasksByOrderingKey.values {
            task.cancel()
        }
        for barrier in idleBarriers {
            barrier.resume()
        }
    }

    /// Synchronously transfers ownership to the actor's admission stream. The
    /// socket can acknowledge immediately after this returns true.
    nonisolated func enqueue(_ event: AgentHookDeliveryEvent) -> Bool {
        switch admissionContinuation.yield(.event(event)) {
        case .enqueued:
            return true
        case .dropped, .terminated:
            return false
        @unknown default:
            return false
        }
    }

    /// Waits until every delivery admitted before this call has finished.
    func waitUntilIdle() async {
        await withCheckedContinuation { continuation in
            switch admissionContinuation.yield(.barrier(continuation)) {
            case .enqueued:
                break
            case .dropped, .terminated:
                continuation.resume()
            @unknown default:
                continuation.resume()
            }
        }
    }

    private func accept(_ admission: Admission) {
        switch admission {
        case .event(let event):
            let orderingKey = event.orderingKey
            pendingByOrderingKey[orderingKey, default: []].append(event)
            guard drainTasksByOrderingKey[orderingKey] == nil else { return }
            drainTasksByOrderingKey[orderingKey] = Task { [weak self] in
                await self?.drain(orderingKey: orderingKey)
            }
        case .barrier(let continuation):
            if pendingByOrderingKey.isEmpty, drainTasksByOrderingKey.isEmpty {
                continuation.resume()
            } else {
                idleBarriers.append(continuation)
            }
        }
    }

    private func drain(orderingKey: String) async {
        while !Task.isCancelled, let event = takeNextEvent(orderingKey: orderingKey) {
            await delivery(event)
        }
        drainTasksByOrderingKey.removeValue(forKey: orderingKey)
        if pendingByOrderingKey[orderingKey]?.isEmpty == false {
            drainTasksByOrderingKey[orderingKey] = Task { [weak self] in
                await self?.drain(orderingKey: orderingKey)
            }
            return
        }
        guard pendingByOrderingKey.isEmpty, drainTasksByOrderingKey.isEmpty else { return }
        let barriers = idleBarriers
        idleBarriers.removeAll(keepingCapacity: true)
        barriers.forEach { $0.resume() }
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
