import Foundation
import Testing

extension LivenessHostRouter {
    @discardableResult
    func waitForCount(
        of method: String,
        atLeast expectedCount: Int,
        timeoutNanoseconds: UInt64 = MobileShellWallClockWaitPolicy.defaultWaitTimeoutNanoseconds,
        recordIssueOnTimeout: Bool = true
    ) async -> Bool {
        let effectiveTimeoutNanoseconds = MobileShellWallClockWaitPolicy
            .timeoutNanoseconds(for: timeoutNanoseconds)
        let operation: @Sendable () async throws -> Bool = {
            try Task.checkCancellation()
            return await withTaskGroup(of: Bool.self) { group in
                group.addTask {
                    await self.waitUntilCountReached(of: method, atLeast: expectedCount)
                    return true
                }
                group.addTask {
                    // Test assertion deadline only; request arrival is signaled by record().
                    try? await Task.sleep(nanoseconds: effectiveTimeoutNanoseconds)
                    return false
                }
                let reached = await group.next() ?? false
                group.cancelAll()
                return reached
            }
        }
        let reached: Bool
        if MobileShellWallClockWaitPolicy.shouldSerializeWait(
            timeoutNanoseconds: timeoutNanoseconds
        ) {
            reached = (try? await MobileShellWallClockWaitGate.processWide.withLock(operation)) ?? false
        } else {
            reached = (try? await operation()) ?? false
        }
        if !reached, recordIssueOnTimeout {
            Issue.record("timed out waiting for \(method) count >= \(expectedCount)")
        }
        return reached
    }

    /// Waits for the transport's real replay-request admission signal. This
    /// is used by tests that need to distinguish an already-started request
    /// from one that must wait for an output acknowledgement.
    @discardableResult
    func waitForReplayRequestStart(
        after existingCount: Int,
        timeoutNanoseconds: UInt64 = 250_000_000
    ) async -> Bool {
        await waitForCount(
            of: "mobile.terminal.replay",
            atLeast: existingCount + 1,
            timeoutNanoseconds: timeoutNanoseconds,
            recordIssueOnTimeout: false
        )
    }

    func waitUntilCountReached(of method: String, atLeast expectedCount: Int) async {
        guard count(of: method) < expectedCount else { return }
        let waiterID = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                countWaiters.append((
                    id: waiterID,
                    method: method,
                    expectedCount: expectedCount,
                    continuation: continuation
                ))
                resumeSatisfiedCountWaiters()
            }
        } onCancel: {
            Task { await self.cancelCountWaiter(id: waiterID) }
        }
    }

    func resumeSatisfiedCountWaiters() {
        var remaining: [(
            id: UUID,
            method: String,
            expectedCount: Int,
            continuation: CheckedContinuation<Void, Never>
        )] = []
        var satisfied: [CheckedContinuation<Void, Never>] = []
        for waiter in countWaiters {
            if count(of: waiter.method) >= waiter.expectedCount {
                satisfied.append(waiter.continuation)
            } else {
                remaining.append(waiter)
            }
        }
        countWaiters = remaining
        for continuation in satisfied {
            continuation.resume()
        }
    }

    func cancelCountWaiter(id: UUID) {
        guard let index = countWaiters.firstIndex(where: { $0.id == id }) else {
            return
        }
        let waiter = countWaiters.remove(at: index)
        waiter.continuation.resume()
    }
}
