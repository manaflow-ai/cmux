@MainActor
final class RelaunchPreparationEventQueue {
    private var bufferedEvents: [RelaunchPreparationEvent] = []
    private var waiter: CheckedContinuation<RelaunchPreparationEvent, Never>?

    func send(_ event: RelaunchPreparationEvent) {
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: event)
        } else {
            bufferedEvents.append(event)
        }
    }

    func next() async -> RelaunchPreparationEvent {
        if !bufferedEvents.isEmpty {
            return bufferedEvents.removeFirst()
        }
        return await withCheckedContinuation { continuation in
            precondition(waiter == nil)
            waiter = continuation
        }
    }
}
