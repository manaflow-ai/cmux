import Foundation

actor GitHubPullRequestTestSignal {
    private var value = 0
    private var waiters: [UUID: (target: Int, continuation: CheckedContinuation<Bool, Never>)] = [:]

    func signal(_ newValue: Int? = nil) {
        if let newValue {
            value = max(value, newValue)
        } else {
            value += 1
        }
        let ready = waiters.filter { $0.value.target <= value }
        for (id, _) in ready { waiters.removeValue(forKey: id) }
        for (_, waiter) in ready { waiter.continuation.resume(returning: true) }
    }

    func wait(until target: Int = 1, timeout: Duration = .seconds(2)) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask { await self.waitWithoutDeadline(until: target) }
            group.addTask {
                // A real deadline prevents a broken async test from hanging the suite.
                do { try await Task.sleep(for: timeout) } catch { return false }
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
    }

    nonisolated static func waitUntil(
        timeout: Duration = .seconds(2),
        condition: @Sendable @escaping () async -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await condition() { return true }
            // This bounded test-only poll observes actor state without a production callback seam.
            do { try await clock.sleep(for: .milliseconds(1)) } catch { return false }
        }
        return await condition()
    }

    private func waitWithoutDeadline(until target: Int) async -> Bool {
        guard value < target else { return true }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: false)
                    return
                }
                waiters[id] = (target, continuation)
            }
        } onCancel: { [weak self] in
            guard let self else { return }
            Task { await self.cancelWaiter(id: id) }
        }
    }

    private func cancelWaiter(id: UUID) {
        waiters.removeValue(forKey: id)?.continuation.resume(returning: false)
    }
}
