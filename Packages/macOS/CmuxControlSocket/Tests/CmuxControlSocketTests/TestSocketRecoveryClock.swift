import CmuxControlSocket
import Foundation
import Testing

final class TestSocketRecoveryClock: SocketRecoveryClock, @unchecked Sendable {
    private typealias Waiter = CheckedContinuation<Void, any Error>
    private enum Registration {
        case wait
        case resume
        case cancel
    }
    private struct State {
        var waiters: [UUID: Waiter] = [:]
        var bufferedAdvanceCount = 0
    }

    private let lock = NSLock()
    private var state = State()

    func sleep(forMilliseconds milliseconds: Int) async throws {
        let id = UUID()
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let registration = withStateLock { state in
                    guard !Task.isCancelled else { return Registration.cancel }
                    if state.bufferedAdvanceCount > 0 {
                        state.bufferedAdvanceCount -= 1
                        return Registration.resume
                    }
                    state.waiters[id] = continuation
                    return Registration.wait
                }
                switch registration {
                case .wait:
                    break
                case .resume:
                    continuation.resume()
                case .cancel:
                    continuation.resume(throwing: CancellationError())
                }
            }
        } onCancel: { [weak self] in
            self?.cancelWaiter(id)
        }
    }

    func advance() {
        let pending = withStateLock { state in
            guard !state.waiters.isEmpty else {
                state.bufferedAdvanceCount += 1
                return [Waiter]()
            }
            let pending = Array(state.waiters.values)
            state.waiters.removeAll(keepingCapacity: true)
            return pending
        }
        for waiter in pending {
            waiter.resume()
        }
    }

    var pendingSleepCount: Int {
        withStateLock { $0.waiters.count }
    }

    private func cancelWaiter(_ id: UUID) {
        let waiter = withStateLock { $0.waiters.removeValue(forKey: id) }
        waiter?.resume(throwing: CancellationError())
    }

    private func withStateLock<T>(_ body: (inout State) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&state)
    }
}

@Test func socketRecoveryClockBuffersAdvanceBeforeSleep() async throws {
    let clock = TestSocketRecoveryClock()
    clock.advance()

    // Returning is the assertion: this fake clock never consults wall time, so
    // the buffered advance must synchronously satisfy the next suspension.
    try await clock.sleep(forMilliseconds: 1_000)
}

@Test func cancelledSocketRecoverySleepFinishesWithoutAdvance() async {
    let clock = TestSocketRecoveryClock()
    let sleeper = Task {
        try await clock.sleep(forMilliseconds: 1_000)
    }
    for _ in 0..<100 where clock.pendingSleepCount == 0 {
        await Task.yield()
    }
    #expect(clock.pendingSleepCount == 1)

    sleeper.cancel()
    do {
        try await sleeper.value
        Issue.record("Expected cancellation to terminate the virtual sleep")
    } catch is CancellationError {
        // Expected.
    } catch {
        Issue.record("Unexpected virtual-clock error: \(error)")
    }
    #expect(clock.pendingSleepCount == 0)
}
