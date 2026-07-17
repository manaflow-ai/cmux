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
    private var waiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

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
            continuation.resume()
        }
    }

    /// Suspends until at least `count` events have been recorded.
    func waitForEventCount(_ count: Int) async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if storedEvents.count >= count {
                lock.unlock()
                continuation.resume()
                return
            }
            waiters.append((count, continuation))
            lock.unlock()
        }
    }
}
