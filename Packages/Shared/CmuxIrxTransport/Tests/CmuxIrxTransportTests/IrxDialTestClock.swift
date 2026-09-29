import Foundation

actor IrxDialTestClock {
    private var sleepers: [UUID: CheckedContinuation<Void, any Error>] = [:]
    private var observers: [CheckedContinuation<Void, Never>] = []

    func sleep() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                sleepers[id] = continuation
                let pending = observers
                observers = []
                pending.forEach { $0.resume() }
            }
        } onCancel: { Task { await self.cancel(id) } }
    }

    func waitUntilArmed() async {
        if !sleepers.isEmpty { return }
        await withCheckedContinuation { observers.append($0) }
    }

    func advance() {
        let pending = sleepers.values
        sleepers = [:]
        pending.forEach { $0.resume() }
    }

    private func cancel(_ id: UUID) {
        sleepers.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }
}
