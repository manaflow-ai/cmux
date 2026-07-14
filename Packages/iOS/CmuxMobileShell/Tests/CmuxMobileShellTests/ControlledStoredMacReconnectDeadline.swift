import Foundation

actor ControlledStoredMacReconnectDeadline {
    private var armCount = 0
    private var armWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var deadlineWaiters: [(id: UUID, continuation: CheckedContinuation<Void, Never>)] = []

    func wait() async {
        armCount += 1
        resumeSatisfiedArmWaiters()
        let id = UUID()
        await withTaskCancellationHandler {
            guard !Task.isCancelled else { return }
            await withCheckedContinuation { continuation in
                deadlineWaiters.append((id, continuation))
            }
        } onCancel: {
            Task { await self.cancel(id: id) }
        }
    }

    func waitUntilArmed() async {
        await waitUntilArmCount(1)
    }

    func waitUntilArmCount(_ expectedCount: Int) async {
        if armCount >= expectedCount { return }
        await withCheckedContinuation { continuation in
            armWaiters.append((expectedCount, continuation))
        }
    }

    func currentArmCount() -> Int { armCount }

    func expire() async {
        guard !deadlineWaiters.isEmpty else { return }
        deadlineWaiters.removeFirst().continuation.resume()
        await Task.yield()
        await Task.yield()
    }

    private func cancel(id: UUID) {
        guard let index = deadlineWaiters.firstIndex(where: { $0.id == id }) else { return }
        deadlineWaiters.remove(at: index).continuation.resume()
    }

    private func resumeSatisfiedArmWaiters() {
        let satisfied = armWaiters.filter { $0.count <= armCount }
        armWaiters.removeAll { $0.count <= armCount }
        for waiter in satisfied {
            waiter.continuation.resume()
        }
    }
}
