internal import Darwin
internal import Observation
internal import os

/// The values of a main-actor expression over time, with the call shape of
/// the Observation module's `Observations` sequence (macOS 26), so that
/// cmux-next runs on macOS 14 (plans/cmux-next/macos-floor.md, cx-s6wi.4).
///
///     for await scale in ObservationStream({ DesignSettings.shared.uiScale }) { ... }
///
/// On macOS 26 and later every iterator forwards to the system `Observations`,
/// so the main population runs Apple's code. On macOS 14 and 15 the iterator
/// below reimplements the same algorithm over `withObservationTracking`
/// (macOS 14), with the same steps in the same order:
///
/// 1. The first `next()` evaluates `emit` on the main actor inside
///    `withObservationTracking` and returns that value at once.
/// 2. Each later `next()` waits for the tracking's `onChange` (a will-set,
///    sent once per tracking), then hops to the main actor, evaluates `emit`
///    again with fresh tracking, and returns that value. The hop queues
///    behind the job that made the change, so the value is the one after the
///    whole main-actor transaction: several changes in one transaction, or
///    while the consumer is busy between two `next()` calls, give one value
///    (the latest), never one value per change.
/// 3. A change that arrives while the consumer is not waiting marks the
///    state dirty, and the next `next()` evaluates at once (no lost update).
/// 4. Cancellation of the iterating task resumes a waiting `next()`, which
///    then returns nil; a cancelled task always gets nil.
///
/// Like the system type it does not drop equal values (use
/// `assignIfChanged` in CmuxNextWakeups on the write side), and it never
/// polls or uses a timer: the only wakeups are the will-set callback, the
/// continuation resume and the main-actor hop, one each per change burst,
/// the same as the system type. Neither path writes to the WakeupLedger, so
/// debug.wakeups counts the same on both.
///
/// Differences from the system type:
/// - `emit` must be main-actor isolated. The system type takes any isolation
///   (`@isolated(any)`); calling such a closure synchronously inside
///   `withObservationTracking` needs a conversion that Swift 6 flags as a
///   future error, so this type takes the isolation that every call site
///   uses. A call site on another actor does not compile; it uses the system
///   `Observations` under `#available(macOS 26, *)`.
/// - No throwing form and no `untilFinished`: no call site needs them.
/// - Deallocation: on macOS 26 the system type wakes once more when an
///   object that `emit` read is deallocated (for example `{ [weak model] in
///   model?.value }` then yields nil). `withObservationTracking` on 14 and 15
///   has no deinit callback, so the fallback does not wake: a loop that waits
///   for that nil to end stays suspended until its task is cancelled. Every
///   owner must cancel its observation task when it goes away (audited
///   2026-10-10: the weak-capture call sites are app-lifetime services or
///   owners that cancel in deinit or teardown). The DEBUG override cannot
///   show this difference, because macOS 26 has the newer registrar.
/// - When the iterator ends or is dropped while a tracking is armed, that
///   tracking stays registered until the next change of a value it read,
///   which then fires into a finished state and does nothing.
/// - Observed values must change on the main actor. A will-set from another
///   thread can reach the main-actor re-evaluation before the new value is
///   stored; the value then comes one change late.
/// - One iterator serves one consumer. Calling `next()` from two tasks at
///   once on copies of one iterator is a programming error (the system type
///   traps); here the second waiter replaces the first.
///
/// DEBUG builds read `CMUX_NEXT_DEBUG_LEGACY_OBSERVATIONS=1` at launch to use
/// the macOS 14 path on macOS 26 too, so the fallback can be compared with
/// the system type on one machine.
public struct ObservationStream<Element: Sendable>: AsyncSequence, Sendable {
    public typealias Failure = Never

    private let emit: @MainActor @Sendable () -> Element

    /// Makes a sequence of the values of `emit`. `emit` runs on the main actor
    /// once when iteration starts and once after each change of an observable
    /// value that it read.
    public init(_ emit: @escaping @MainActor @Sendable () -> Element) {
        self.emit = emit
    }

    public func makeAsyncIterator() -> Iterator {
        // The system-iterator path (NativeIterator) traps at launch on macOS 27
        // (exit 133); every OS uses the withObservationTracking path until it is fixed.
        if #available(macOS 26, *), ObservationStreamNativeOptIn.enabled {
            return Iterator(native: NativeIterator(emit))
        }
        return Iterator(legacy: LegacyIterator(emit: emit))
    }

    public struct Iterator: AsyncIteratorProtocol {
        public typealias Failure = Never

        /// A ``NativeIterator`` on macOS 26 (a stored property cannot name a
        /// type that is newer than the deployment target).
        private let native: AnyObject?
        private var legacy: LegacyIterator?

        fileprivate init(native: AnyObject) {
            self.native = native
        }

        fileprivate init(legacy: LegacyIterator) {
            native = nil
            self.legacy = legacy
        }

        public mutating func next(isolation iteratorIsolation: isolated (any Actor)? = #isolation) async -> Element? {
            if #available(macOS 26, *), let native = native as? NativeIterator {
                return await native.next(isolation: iteratorIsolation)
            }
            return await legacy?.next(isolation: iteratorIsolation)
        }

        public mutating func next() async -> Element? {
            await next(isolation: #isolation)
        }
    }

    /// The system iterator in a box, so that ``Iterator`` can hold it.
    @available(macOS 26, *)
    fileprivate final class NativeIterator {
        private var base: Observations<Element, Never>.Iterator

        init(_ emit: @escaping @MainActor @Sendable () -> Element) {
            base = Observations<Element, Never>(emit).makeAsyncIterator()
        }

        func next(isolation iteratorIsolation: isolated (any Actor)?) async -> Element? {
            await base.next(isolation: iteratorIsolation)
        }
    }

    /// The macOS 14 and 15 iterator (see the type comment).
    fileprivate struct LegacyIterator {
        private var emit: (@MainActor @Sendable () -> Element)?
        private let state = ChangeState()
        private var started = false

        init(emit: @escaping @MainActor @Sendable () -> Element) {
            self.emit = emit
        }

        mutating func next(isolation iteratorIsolation: isolated (any Actor)?) async -> Element? {
            guard let emit else { return nil }
            let state = state
            if started {
                await withTaskCancellationHandler {
                    await state.waitForChange()
                } onCancel: {
                    state.cancel()
                }
            }
            started = true
            guard !Task.isCancelled else {
                finish()
                return nil
            }
            return await Self.track(emit, state: state)
        }

        private mutating func finish() {
            emit = nil
            state.cancel()
        }

        /// Evaluates `emit` with fresh tracking. The `await` at the call site
        /// is the hop to the main actor (no hop when the iterator already runs
        /// there, as with the system type).
        @MainActor
        private static func track(_ emit: @MainActor @Sendable () -> Element, state: ChangeState) -> Element {
            withObservationTracking {
                emit()
            } onChange: { [state] in
                state.changed()
            }
        }
    }

    /// The handoff between the tracking's will-set callback (any thread) and
    /// the one waiting `next()`.
    fileprivate final class ChangeState: Sendable {
        private struct Inner {
            var waiter: CheckedContinuation<Void, Never>?
            var dirty = false
            var cancelled = false
        }

        private let inner = Mutex(Inner())

        /// The will-set callback: wakes the waiting `next()`, or marks the
        /// state dirty so the next `next()` does not wait.
        func changed() {
            let waiter = inner.withLock { s -> CheckedContinuation<Void, Never>? in
                guard let waiter = s.waiter else {
                    s.dirty = true
                    return nil
                }
                s.waiter = nil
                return waiter
            }
            waiter?.resume()
        }

        /// Ends every wait now and later.
        func cancel() {
            let waiter = inner.withLock { s -> CheckedContinuation<Void, Never>? in
                s.cancelled = true
                defer { s.waiter = nil }
                return s.waiter
            }
            waiter?.resume()
        }

        /// Returns after the next change, at once when a change came since the
        /// last evaluation or the iteration was cancelled.
        /// Runs on the caller's isolation (nonisolated(nonsending)).
        func waitForChange() async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let resumeNow = inner.withLock { s -> Bool in
                    if s.cancelled || s.dirty {
                        s.dirty = false
                        return true
                    }
                    s.waiter = continuation
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        }
    }
}

/// The DEBUG switch that forces the macOS 14 path of ``ObservationStream``
/// (read once, at the first iterator).
struct ObservationStreamLegacyOverride {
    static let enabled: Bool = {
        #if DEBUG
        guard let raw = getenv("CMUX_NEXT_DEBUG_LEGACY_OBSERVATIONS"), String(cString: raw) == "1" else {
            return false
        }
        Logger(subsystem: "com.cmuxterm.app.next", category: "observation-stream")
            .notice("CMUX_NEXT_DEBUG_LEGACY_OBSERVATIONS=1: every ObservationStream uses the withObservationTracking path")
        return true
        #else
        return false
        #endif
    }()
}

/// DEBUG opt-in to the system-iterator path (`CMUX_NEXT_DEBUG_NATIVE_OBSERVATIONS=1`), for its fix.
struct ObservationStreamNativeOptIn {
    static let enabled: Bool = {
        #if DEBUG
        guard let raw = getenv("CMUX_NEXT_DEBUG_NATIVE_OBSERVATIONS") else { return false }
        return String(cString: raw) == "1"
        #else
        return false
        #endif
    }()
}
