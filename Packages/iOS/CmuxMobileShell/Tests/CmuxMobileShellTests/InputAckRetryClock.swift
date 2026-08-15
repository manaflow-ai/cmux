import Foundation

/// Hand-advanced clock for the input-ACK resubscribe freshness delay.
///
/// Safety: every mutable field is accessed under `lock`.
final class InputAckRetryClock: Clock, @unchecked Sendable {
    struct Instant: InstantProtocol {
        var offset: Duration

        func advanced(by duration: Duration) -> Instant {
            Instant(offset: offset + duration)
        }

        func duration(to other: Instant) -> Duration {
            other.offset - offset
        }

        static func < (lhs: Instant, rhs: Instant) -> Bool {
            lhs.offset < rhs.offset
        }
    }

    private struct Sleeper {
        let id: UUID
        let deadline: Instant
        let continuation: UnsafeContinuation<Void, any Error>
    }

    private let lock = NSLock()
    private var current = Instant(offset: .zero)
    private var sleepers: [Sleeper] = []
    private var preCancelledIDs: Set<UUID> = []

    var now: Instant {
        lock.withLock { current }
    }

    var minimumResolution: Duration { .zero }

    var sleeperCount: Int {
        lock.withLock { sleepers.count }
    }

    func sleep(until deadline: Instant, tolerance _: Duration?) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withUnsafeThrowingContinuation {
                (continuation: UnsafeContinuation<Void, any Error>) in
                lock.lock()
                if preCancelledIDs.remove(id) != nil {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                } else if deadline <= current {
                    lock.unlock()
                    continuation.resume()
                } else {
                    sleepers.append(Sleeper(
                        id: id,
                        deadline: deadline,
                        continuation: continuation
                    ))
                    lock.unlock()
                }
            }
        } onCancel: {
            cancelSleeper(id: id)
        }
    }

    func advance(by duration: Duration) {
        lock.lock()
        current = current.advanced(by: duration)
        let due = sleepers
            .filter { $0.deadline <= current }
            .sorted { $0.deadline < $1.deadline }
        sleepers.removeAll { $0.deadline <= current }
        lock.unlock()
        for sleeper in due {
            sleeper.continuation.resume()
        }
    }

    private func cancelSleeper(id: UUID) {
        lock.lock()
        guard let index = sleepers.firstIndex(where: { $0.id == id }) else {
            preCancelledIDs.insert(id)
            lock.unlock()
            return
        }
        let sleeper = sleepers.remove(at: index)
        lock.unlock()
        sleeper.continuation.resume(throwing: CancellationError())
    }
}
