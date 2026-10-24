public import Foundation
import CmuxNextCompat

/// One store's saves, landing in the order they were made, on the ``BackgroundWork`` files lane.
///
/// A store that saves on every change (themes, ledgers, lists) calls ``save(_:to:)`` (or
/// ``enqueue(_:)`` for its own write) from its own actor. Each save is queued at once at
/// ``WorkPriority/bestEffort`` on the files lane's serial slot, so saves land in call order with no
/// chain of tasks and no cooperative-pool thread waiting on the disk. Each save is
/// ``ShutdownBehavior/blockShutdown``: `BackgroundWork.shutdown()` at quit waits for it.
///
/// ```swift
/// let writes = OrderedWrites(work: work) { logger.error("themes write failed: \($0)") }
/// writes.save(try? JSONEncoder().encode(themes), to: url)  // nil removes the file
/// await writes.flush()                                     // tests: every save so far landed
/// ```
public final class OrderedWrites: Sendable {
    private struct State {
        var queued: UInt64 = 0
        var landed: UInt64 = 0
        var waiters: [(number: UInt64, continuation: CheckedContinuation<Void, Never>)] = []
    }

    private let work: BackgroundWork
    private let failed: @Sendable (any Error) -> Void
    // concurrency-allow: a save counter and flush waiters, taken by callers and the lane thread (lock carve-out: no I/O under it).
    private let state = Mutex(State())

    /// - Parameters:
    ///   - work: the app's blocking-work lanes.
    ///   - failed: called on the lane thread with a save's error (the store logs it).
    public init(work: BackgroundWork, failed: @escaping @Sendable (any Error) -> Void) {
        self.work = work
        self.failed = failed
    }

    /// Queues `data` written atomically to `url` (its folder created first), or `url` removed when
    /// `data` is nil.
    public func save(_ data: Data?, to url: URL) {
        enqueue {
            if let data {
                try FileManager.checked.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.blockingWrite(to: url, options: .atomic)
            } else if FileManager.checked.fileExists(atPath: url.path) {
                try FileManager.checked.removeItem(at: url)
            }
        }
    }

    /// Queues `write` after every save queued before it; its error goes to `failed`.
    public func enqueue(_ write: @escaping @Sendable () throws -> Void) {
        let number = state.withLock { state -> UInt64 in
            state.queued += 1
            return state.queued
        }
        let failed = failed
        work.post(.bestEffort, mayBlock: .files, shutdown: .blockShutdown) { [self] in
            do { try write() } catch { failed(error) }
            landed(number)
        }
    }

    /// Returns when every save queued before the call has landed.
    public func flush() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let now = state.withLock { state -> Bool in
                if state.landed >= state.queued { return true }
                state.waiters.append((state.queued, continuation))
                return false
            }
            if now { continuation.resume() }
        }
    }

    private func landed(_ number: UInt64) {
        let ready = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.landed = max(state.landed, number)
            let landed = state.landed
            let ready = state.waiters.filter { $0.number <= landed }.map(\.continuation)
            state.waiters.removeAll { $0.number <= landed }
            return ready
        }
        for waiter in ready { waiter.resume() }
    }
}
