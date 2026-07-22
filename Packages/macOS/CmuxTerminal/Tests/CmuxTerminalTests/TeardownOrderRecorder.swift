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
    }

    private var waiters: [Waiter] = []

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
        let resumable = waiters.filter { $0.count <= count }.map(\.continuation)
        waiters.removeAll { $0.count <= count }
        lock.unlock()
        for continuation in resumable {
            continuation.resume(returning: true)
        }
    }

    /// Suspends until at least `count` events have been recorded, or returns
    /// false after a bounded wait so a failed teardown cannot hang the suite.
    func waitForEventCount(_ count: Int, timeout: TimeInterval = 1) async -> Bool {
        let waiterID = UUID()
        return await withCheckedContinuation { continuation in
            lock.lock()
            if storedEvents.count >= count {
                lock.unlock()
                continuation.resume(returning: true)
                return
            }
            waiters.append(Waiter(id: waiterID, count: count, continuation: continuation))
            lock.unlock()

            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.expireWaiter(id: waiterID)
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
}
