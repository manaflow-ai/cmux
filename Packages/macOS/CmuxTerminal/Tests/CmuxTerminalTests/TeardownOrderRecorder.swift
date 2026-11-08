import Foundation

/// Records the order of teardown events emitted by synchronous callbacks (an
/// injected native free running on the teardown coordinator's worker, a byte-tee
/// lease release) and lets tests await a target event count without polling.
///
/// @unchecked Sendable: all state is guarded by `lock`; the recording entry
/// points are synchronous callbacks with no async context (the sanctioned lock
/// carve-out for off-isolation compare-and-set).
final class TeardownOrderRecorder: @unchecked Sendable {
    enum Event: Equatable, Sendable {
        case nativeFree
        case teeLeaseRelease
    }

    private let lock = NSLock()
    private var storedEvents: [Event] = []
    private struct Waiter {
        let id: UUID
        let count: Int
        let continuation: CheckedContinuation<Bool, Never>
        let timeoutTask: Task<Void, Never>
    }

    private var waiters: [Waiter] = []
    private var waiterRegistrationSignals: [CheckedContinuation<Void, Never>] = []

    /// The events recorded so far, in order.
    var events: [Event] {
        lock.lock()
        defer { lock.unlock() }
        return storedEvents
    }

    /// Records an event and resumes any waiter whose target count is reached.
    func record(_ event: Event) {
        lock.lock()
        storedEvents.append(event)
        let count = storedEvents.count
        let resumable = waiters.filter { $0.count <= count }
        waiters.removeAll { $0.count <= count }
        lock.unlock()
        for waiter in resumable {
            waiter.timeoutTask.cancel()
            waiter.continuation.resume(returning: true)
        }
    }

    /// Suspends until at least `count` events have been recorded, or returns
    /// false after a bounded wait so a failed teardown cannot hang the suite.
    func waitForEventCount(_ count: Int, timeout: Duration = .seconds(5)) async -> Bool {
        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                lock.lock()
                if Task.isCancelled {
                    lock.unlock()
                    continuation.resume(returning: false)
                    return
                }
                if storedEvents.count >= count {
                    lock.unlock()
                    continuation.resume(returning: true)
                    return
                }

                let timeoutTask = Task { [weak self] in
                    do {
                        // Genuine test deadline; event delivery or parent cancellation cancels this task.
                        try await Task.sleep(for: timeout)
                    } catch {
                        return
                    }
                    self?.expireWaiter(id: waiterID)
                }
                waiters.append(
                    Waiter(
                        id: waiterID,
                        count: count,
                        continuation: continuation,
                        timeoutTask: timeoutTask
                    )
                )
                let registrationSignals = waiterRegistrationSignals
                waiterRegistrationSignals.removeAll()
                lock.unlock()
                for signal in registrationSignals { signal.resume() }
            }
        } onCancel: {
            cancelWaiter(id: waiterID)
        }
    }

    /// Suspends until an event-count waiter is installed. Tests use this to
    /// cancel the registered waiter instead of racing its setup task.
    func waitUntilEventWaiterIsRegistered() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if waiters.isEmpty {
                waiterRegistrationSignals.append(continuation)
                lock.unlock()
            } else {
                lock.unlock()
                continuation.resume()
            }
        }
    }

    private func expireWaiter(id: UUID) {
        lock.lock()
        guard let index = waiters.firstIndex(where: { $0.id == id }) else {
            lock.unlock()
            return
        }
        let continuation = waiters.remove(at: index).continuation
        lock.unlock()
        continuation.resume(returning: false)
    }

    private func cancelWaiter(id: UUID) {
        lock.lock()
        guard let index = waiters.firstIndex(where: { $0.id == id }) else {
            lock.unlock()
            return
        }
        let waiter = waiters.remove(at: index)
        lock.unlock()
        waiter.timeoutTask.cancel()
        waiter.continuation.resume(returning: false)
    }
}
