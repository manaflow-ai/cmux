internal import Foundation

/// Bounds renderer-to-main-actor frame delivery to one pending hop.
///
/// Each claim returns a generation ticket. Consuming or cancelling that ticket
/// releases the slot, while a stale task cannot release a newer claim.
final class RenderedFrameDeliveryGate: Sendable {
    struct Ticket: Equatable, Sendable {
        fileprivate let generation: UInt64
    }

    private let lock = NSLock()
    // SAFETY: both values are accessed only while `lock` is held.
    nonisolated(unsafe) private var nextGeneration: UInt64 = 0
    nonisolated(unsafe) private var pendingGeneration: UInt64?

    func claim() -> Ticket? {
        lock.lock()
        defer { lock.unlock() }
        guard pendingGeneration == nil else { return nil }

        nextGeneration &+= 1
        pendingGeneration = nextGeneration
        return Ticket(generation: nextGeneration)
    }

    func consume(_ ticket: Ticket) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard pendingGeneration == ticket.generation else { return false }

        pendingGeneration = nil
        return true
    }

    func cancel() {
        lock.lock()
        pendingGeneration = nil
        lock.unlock()
    }
}
