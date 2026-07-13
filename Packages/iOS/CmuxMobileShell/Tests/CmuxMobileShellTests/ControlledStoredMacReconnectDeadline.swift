import Foundation

actor ControlledStoredMacReconnectDeadline {
    private var armCount = 0
    private var armWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var deadlineWaiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        armCount += 1
        resumeSatisfiedArmWaiters()
        await withCheckedContinuation { continuation in
            deadlineWaiters.append(continuation)
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
        deadlineWaiters.removeFirst().resume()
        await Task.yield()
        await Task.yield()
    }

    private func resumeSatisfiedArmWaiters() {
        let satisfied = armWaiters.filter { $0.count <= armCount }
        armWaiters.removeAll { $0.count <= armCount }
        for waiter in satisfied {
            waiter.continuation.resume()
        }
    }
}
