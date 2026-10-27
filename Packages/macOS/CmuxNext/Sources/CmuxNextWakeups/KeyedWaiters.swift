import class CmuxSafeConcurrency.OnceContinuation
import enum CmuxSafeConcurrency.OnceContinuationError
import func CmuxSafeConcurrency.withOnceContinuation

/// One-shot waits filed under the key whose change can satisfy them (plans/cmux-next/chrome-parity/
/// p06-scheduler.md, section C): the engine under the store's waits (`StoreWaiters`, task 027) and a
/// page's waits (`PageWaiters`, task 028).
///
/// The owner calls ``settle(_:with:)`` when `slot`'s state changed; only that slot's waiters read
/// their condition, so N waiters on other keys cost nothing (Chromium signals its waiters from the
/// change itself, never from a poll: `base/one_shot_event.h`).
///
/// A wait resumes exactly once: with its value when its condition holds, or with nil when its
/// timeout passes, when the waiting task is cancelled, or when the owner ends (``end()``). Every
/// wait has a timeout, a deadline on the main thread's one deadline queue (``AlignedWakeups`` over
/// ``MainWakeUpQueue``, Chromium's `WakeUpQueue` in base/task/sequence_manager/wake_up_queue.h), so
/// pending waits share its heap and its aligned wakes and no waiter has a Task or timer of its own.
@MainActor public final class KeyedWaiters<Slot: Hashable & Sendable, Subject> {
    /// One waiter: resumed exactly once, by `resumeIfReady` or `abandon`, after which it is dropped
    /// and its timeout cancelled.
    private struct Waiter {
        /// Resumes with the condition's value when it holds for the subject; whether it did.
        let resumeIfReady: @MainActor (Subject) -> Bool
        /// Resumes with nil (timeout, cancel, end).
        let abandon: @MainActor () -> Void
        let ticket: AlignedWakeups.Ticket
    }

    private let deadlines: AlignedWakeups
    private let deadlineOwner: String
    private var waiting: [Slot: [UInt64: Waiter]] = [:]
    private var nextSerial: UInt64 = 0
    private var hasEnded = false
    /// ``untilPending(_:)`` calls waiting for a count.
    private var pendingWatchers: [(count: Int, continuation: OnceContinuation<Void, OnceContinuationError>)] = []
    /// Waiter conditions read since creation, at registration and at settle (tests: a change of
    /// another key reads none).
    public private(set) var evaluations = 0
    /// Waiters still waiting.
    public private(set) var pendingCount = 0

    /// - Parameters:
    ///   - deadlines: Where the waits' timeouts go: the main thread's one deadline queue.
    ///   - deadlineOwner: The `WakeupLedger` owner of those timeouts.
    public init(deadlines: AlignedWakeups, deadlineOwner: String) {
        self.deadlines = deadlines
        self.deadlineOwner = deadlineOwner
    }

    /// No waiter is waiting.
    public var isEmpty: Bool { waiting.isEmpty }

    /// The slots with waiters.
    public var slots: [Slot] { Array(waiting.keys) }

    /// Whether `slot` has waiters.
    public func hasWaiters(_ slot: Slot) -> Bool { waiting[slot] != nil }

    // MARK: Settle

    /// Reads `slot`'s conditions against `subject`, oldest waiter first, and resumes the ones it satisfies.
    public func settle(_ slot: Slot, with subject: Subject) {
        guard let waiters = waiting[slot] else { return }
        for (serial, waiter) in waiters.sorted(by: { $0.key < $1.key }) {
            evaluations += 1
            if waiter.resumeIfReady(subject) { take(slot, serial) }
        }
    }

    /// The owner ended (a page closed): every wait resumes with nil, oldest first, and later waits
    /// return nil at once.
    public func end() {
        hasEnded = true
        let pending = waiting.flatMap { entry in entry.value.keys.map { (slot: entry.key, serial: $0) } }
        for entry in pending.sorted(by: { $0.serial < $1.serial }) { abandon(entry.slot, entry.serial) }
    }

    // MARK: Waiting

    /// Returns `read(now)` once it is non-nil, read now and then only at `slot`'s settles; nil after
    /// `timeout`, when the calling task is cancelled or after ``end()``.
    public func value<Value: Sendable>(of slot: Slot, now: Subject, timeout: Duration,
                                       read: @escaping @MainActor (Subject) -> Value?) async -> Value? {
        evaluations += 1
        if let value = read(now) { return value }
        guard !hasEnded, !Task.isCancelled else { return nil }
        nextSerial &+= 1
        let serial = nextSerial
        return await withTaskCancellationHandler {
            // A waiter dropped unresumed (abandoned) returns nil, as a timeout does.
            try? await withOnceContinuation { (continuation: OnceContinuation<Value?, OnceContinuationError>) in
                // Cancelled between the check above and here: the handler's hop finds nothing to drop.
                guard !Task.isCancelled else {
                    continuation.resume(returning: nil)
                    return
                }
                // Strong: the queue keeps the waiters until the deadline resumes this wait, whoever drops the owner.
                let ticket = deadlines.schedule(owner: deadlineOwner, after: timeout) { self.abandon(slot, serial) }
                let waiter = Waiter(
                    resumeIfReady: { subject in
                        guard let value = read(subject) else { return false }
                        continuation.resume(returning: value)
                        return true
                    },
                    abandon: { continuation.resume(returning: nil) },
                    ticket: ticket
                )
                file(waiter, under: slot, serial)
            }
        } onCancel: {
            // task-owner: one hop to the main actor that owns the waiters; a waiter already resumed is not found.
            // main-hop-allow: a cancel handler runs on any thread; the hop only drops the cancelled waiter's slot (a resumed one is not found)
            Task { @MainActor in self.abandon(slot, serial) }
        }
    }

    /// Returns once at least `count` waiters are waiting (tests: a wait started in a task has filed itself).
    public func untilPending(_ count: Int) async {
        guard pendingCount < count else { return }
        try? await withOnceContinuation { (continuation: OnceContinuation<Void, OnceContinuationError>) in
            pendingWatchers.append((count, continuation))
        }
    }

    private func file(_ waiter: Waiter, under slot: Slot, _ serial: UInt64) {
        waiting[slot, default: [:]][serial] = waiter
        pendingCount += 1
        guard !pendingWatchers.isEmpty else { return }
        let ready = pendingWatchers.filter { $0.count <= pendingCount }
        pendingWatchers.removeAll { $0.count <= pendingCount }
        for watcher in ready { watcher.continuation.resume(returning: ()) }
    }

    private func abandon(_ slot: Slot, _ serial: UInt64) {
        take(slot, serial)?.abandon()
    }

    /// Drops the waiter and its pending deadline; nil when it already resumed.
    @discardableResult
    private func take(_ slot: Slot, _ serial: UInt64) -> Waiter? {
        guard let waiter = waiting[slot]?.removeValue(forKey: serial) else { return nil }
        pendingCount -= 1
        if waiting[slot]?.isEmpty == true { waiting[slot] = nil }
        deadlines.cancel(waiter.ticket)
        return waiter
    }

    nonisolated deinit {}
}
