@testable import CmuxWorkspaceShare
import Testing

@Suite
struct WorkspaceShareSessionLifecycleTests {
    @Test
    func `Reconnect transitions use the injected clock and randomness`() async {
        let clock = ManualClock()
        let lifecycle = WorkspaceShareSessionLifecycle(
            clockSleep: { duration in
                try await clock.sleep(for: duration)
            },
            randomUnitInterval: { 1 }
        )
        var states = (await lifecycle.states()).makeAsyncIterator()

        #expect(await states.next() == .idle)
        await lifecycle.start()
        #expect(await states.next() == .connecting(attempt: 0))
        await lifecycle.connectionOpened()
        #expect(await states.next() == .connected)

        await lifecycle.connectionFailed(.transport)
        #expect(
            await states.next()
                == .reconnecting(attempt: 1, delay: .milliseconds(625))
        )
        #expect(await clock.nextRequestedSleep() == .milliseconds(625))

        await clock.advanceNext()
        #expect(await states.next() == .connecting(attempt: 1))
        await lifecycle.connectionOpened()
        #expect(await states.next() == .connected)

        await lifecycle.connectionFailed(.transport)
        #expect(
            await states.next()
                == .reconnecting(attempt: 1, delay: .milliseconds(625))
        )
        #expect(await clock.nextRequestedSleep() == .milliseconds(625))
        await lifecycle.stop()
    }

    @Test
    func `Stop cancels a pending reconnect and permanently finishes the stream`() async {
        let clock = ManualClock()
        let lifecycle = WorkspaceShareSessionLifecycle(
            clockSleep: { duration in
                try await clock.sleep(for: duration)
            },
            randomUnitInterval: { 0 }
        )
        var states = (await lifecycle.states()).makeAsyncIterator()

        #expect(await states.next() == .idle)
        await lifecycle.start()
        #expect(await states.next() == .connecting(attempt: 0))
        await lifecycle.connectionOpened()
        #expect(await states.next() == .connected)
        await lifecycle.connectionFailed(.transport)
        #expect(
            await states.next()
                == .reconnecting(attempt: 1, delay: .milliseconds(500))
        )
        #expect(await clock.nextRequestedSleep() == .milliseconds(500))

        await lifecycle.stop()

        #expect(await states.next() == .stopped)
        #expect(await states.next() == nil)
        #expect(await clock.cancelledSleeps == [.milliseconds(500)])
        #expect(await lifecycle.state == .stopped)

        await lifecycle.start()
        #expect(await lifecycle.state == .stopped)
    }

    @Test
    func `Permanent connection failure stops without sleeping`() async {
        let clock = ManualClock()
        let lifecycle = WorkspaceShareSessionLifecycle(
            clockSleep: { duration in
                try await clock.sleep(for: duration)
            },
            randomUnitInterval: { 0 }
        )
        var states = (await lifecycle.states()).makeAsyncIterator()

        #expect(await states.next() == .idle)
        await lifecycle.start()
        #expect(await states.next() == .connecting(attempt: 0))
        await lifecycle.connectionFailed(.http(statusCode: 401, retryAfter: nil))

        #expect(await states.next() == .stopped)
        #expect(await states.next() == nil)
        #expect(await clock.requestedSleeps.isEmpty)
    }

    @Test
    func `Pending send budget rejects count and byte overflow until sends drain`() {
        var budget = WorkspaceSharePendingSendBudget(
            maximumMessages: 2,
            maximumBytes: 10
        )

        #expect(budget.reserve(byteCount: 4))
        #expect(budget.reserve(byteCount: 6))
        #expect(!budget.reserve(byteCount: 1))

        budget.release(byteCount: 4)
        #expect(budget.reserve(byteCount: 4))
        #expect(!budget.reserve(byteCount: 1))

        budget.reset()
        #expect(budget.reserve(byteCount: 10))
        #expect(!budget.reserve(byteCount: 1))
    }

    private actor ManualClock {
        private struct PendingSleep {
            let duration: Duration
            let continuation: CheckedContinuation<Void, any Error>
        }

        private var nextID = 0
        private var pendingOrder: [Int] = []
        private var pending: [Int: PendingSleep] = [:]
        private var requestQueue: [Duration] = []
        private var requestWaiters: [CheckedContinuation<Duration, Never>] = []
        private(set) var requestedSleeps: [Duration] = []
        private(set) var cancelledSleeps: [Duration] = []

        func sleep(for duration: Duration) async throws {
            let id = nextID
            nextID += 1
            try await withTaskCancellationHandler {
                try Task.checkCancellation()
                try await withCheckedThrowingContinuation { continuation in
                    pendingOrder.append(id)
                    pending[id] = PendingSleep(
                        duration: duration,
                        continuation: continuation
                    )
                    requestedSleeps.append(duration)
                    if requestWaiters.isEmpty {
                        requestQueue.append(duration)
                    } else {
                        requestWaiters.removeFirst().resume(returning: duration)
                    }
                }
            } onCancel: {
                Task {
                    await self.cancel(id: id)
                }
            }
        }

        func nextRequestedSleep() async -> Duration {
            if !requestQueue.isEmpty {
                return requestQueue.removeFirst()
            }
            return await withCheckedContinuation { continuation in
                requestWaiters.append(continuation)
            }
        }

        func advanceNext() {
            guard !pendingOrder.isEmpty else { return }
            let id = pendingOrder.removeFirst()
            pending.removeValue(forKey: id)?.continuation.resume()
        }

        private func cancel(id: Int) {
            guard let sleep = pending.removeValue(forKey: id) else { return }
            pendingOrder.removeAll { $0 == id }
            cancelledSleeps.append(sleep.duration)
            sleep.continuation.resume(throwing: CancellationError())
        }
    }
}
