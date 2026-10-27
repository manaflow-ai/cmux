#if canImport(Darwin)
internal import Darwin
#elseif canImport(Glibc)
internal import Glibc
#endif
internal import Observation
#if canImport(os)
internal import os
#endif
internal import class CmuxSafeConcurrency.OnceContinuation
internal import enum CmuxSafeConcurrency.OnceContinuationError
internal import func CmuxSafeConcurrency.withOnceContinuation

/// The values of a main-actor expression over time, with the call shape of
/// the Observation module's `Observations` sequence (macOS 26), so that
/// cmux-next runs on macOS 14 (plans/cmux-next/macos-floor.md, cx-s6wi.4).
///
///     for await scale in ObservationStream({ DesignSettings.shared.uiScale }) { ... }
///
/// New code does not add a loop over this type (plans/cmux-next/chrome-parity/p06-scheduler.md,
/// rule 3 and Q2). A loop's flushes run in no class and keep no owner, and a hidden view's loop
/// keeps reading. Use one of the two scheduled observers in CmuxNextWakeups instead, each with
/// a class and an owner:
/// - `VisibleObservation(node, owner:, on:, read:, apply:)` when `apply` only touches views: it stops
///   reading while its visibility node is hidden.
/// - `ServiceObservation(class, owner:, on:, read:, apply:)` for anything else (the model, the
///   daemon, the disk, another owner): it keeps running while hidden.
/// Both coalesce a burst of changes to one task per frame and cancel when their token is
/// released. Swift cannot deprecate this type for some importing targets only, so the Q2
/// `git grep` count is the guard, not an `@available` attribute.
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
/// Unlike the system type, a stream whose `Element` is `Equatable` emits
/// only values that differ from the last one it emitted (perf-speed-of-light.md
/// I1): a re-evaluation that gives an equal value wakes no consumer. The
/// check is made once per iterator (`Element.self is any Equatable.Type`),
/// so it holds for every Equatable element, Optional and collections of
/// Equatable values included, on both paths. A stream of a non-Equatable
/// element (`Void`, tuples, classes) emits every re-evaluation: a consumer
/// that needs a wakeup for a change its value does not show returns `Void`
/// (`{ _ = model.a; _ = model.b }`), never an equal value. It never
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
public struct ObservationStream<Element: Sendable>: AsyncSequence, Sendable {
    public typealias Failure = Never

    private let emit: @MainActor @Sendable () -> Element
    /// Set by `current(_:)`: the tracking armed by the evaluation it returned, and that value.
    private let primed: Primed?

    fileprivate struct Primed: Sendable {
        let state: ChangeState
        let value: Element
        /// The primed tracking serves one iterator; a later one starts unprimed.
        let once = OneShot()
    }

    fileprivate final class OneShot: Sendable {
        private let taken = Mutex(false)
        /// True the first time only.
        func take() -> Bool { taken.withLock { taken in defer { taken = true }; return !taken } }
    }

    /// Makes a sequence of the values of `emit`. `emit` runs on the main actor
    /// once when iteration starts and once after each change of an observable
    /// value that it read.
    public init(_ emit: @escaping @MainActor @Sendable () -> Element) {
        self.emit = emit
        primed = nil
    }

    private init(_ emit: @escaping @MainActor @Sendable () -> Element, primed: Primed) {
        self.emit = emit
        self.primed = primed
    }

    /// Evaluates `emit` now, on the main actor, with tracking, and returns that value with the
    /// stream of the later values: its first `next()` waits for a change of what this evaluation
    /// read. For a consumer that applies the first value in its own turn (the first frame), so
    /// the value is computed once, not again by the stream's first `next()`. The first iterator
    /// gets the primed tracking; another starts as a plain stream. Always the
    /// `withObservationTracking` path (also with the native opt-in).
    @MainActor
    public static func current(_ emit: @escaping @MainActor @Sendable () -> Element) -> (value: Element, later: ObservationStream) {
        let state = ChangeState()
        let value = LegacyIterator.track(emit, state: state)
        return (value, ObservationStream(emit, primed: Primed(state: state, value: value)))
    }

    public func makeAsyncIterator() -> Iterator {
        if let primed, primed.once.take() {
            return Iterator(legacy: LegacyIterator(emit: emit, state: primed.state), isEqual: Self.equality(), last: primed.value)
        }
        // The system-iterator path (NativeIterator) traps at launch on macOS 27
        // (exit 133); every OS uses the withObservationTracking path until it is fixed.
        if #available(macOS 26, *), ObservationStreamNativeOptIn.enabled {
            return Iterator(native: NativeIterator(emit), isEqual: Self.equality())
        }
        return Iterator(legacy: LegacyIterator(emit: emit), isEqual: Self.equality())
    }

    /// `==` for an `Equatable` element, nil for any other (no dedupe).
    private static func equality() -> (@Sendable (Element, Element) -> Bool)? {
        guard let type = Element.self as? any Equatable.Type else { return nil }
        return equality(type)
    }

    private static func equality<E: Equatable>(_: E.Type) -> @Sendable (Element, Element) -> Bool {
        { lhs, rhs in (lhs as? E) == (rhs as? E) }
    }

    public struct Iterator: AsyncIteratorProtocol {
        public typealias Failure = Never

        /// A ``NativeIterator`` on macOS 26 (a stored property cannot name a
        /// type that is newer than the deployment target).
        private let native: AnyObject?
        private var legacy: LegacyIterator?
        /// `==` of an Equatable element; nil emits every value.
        private let isEqual: (@Sendable (Element, Element) -> Bool)?
        /// The last value emitted (Equatable elements only).
        private var last: Element?

        fileprivate init(native: AnyObject, isEqual: (@Sendable (Element, Element) -> Bool)?) {
            self.native = native
            self.isEqual = isEqual
        }

        fileprivate init(legacy: LegacyIterator, isEqual: (@Sendable (Element, Element) -> Bool)?, last: Element? = nil) {
            native = nil
            self.legacy = legacy
            self.isEqual = isEqual
            self.last = isEqual == nil ? nil : last
        }

        public mutating func next(isolation iteratorIsolation: isolated (any Actor)? = #isolation) async -> Element? {
            while let value = await nextEvaluation(isolation: iteratorIsolation) {
                guard let isEqual else { return value }
                // An equal re-evaluation wakes no consumer: wait for the next change.
                if let last, isEqual(last, value) { continue }
                last = value
                return value
            }
            return nil
        }

        private mutating func nextEvaluation(isolation iteratorIsolation: isolated (any Actor)?) async -> Element? {
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
        private let state: ChangeState
        private var started: Bool

        init(emit: @escaping @MainActor @Sendable () -> Element) {
            self.emit = emit
            state = ChangeState()
            started = false
        }

        /// An iterator whose first evaluation already ran with `state`'s tracking (`current(_:)`).
        init(emit: @escaping @MainActor @Sendable () -> Element, state: ChangeState) {
            self.emit = emit
            self.state = state
            started = true
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
        static func track(_ emit: @MainActor @Sendable () -> Element, state: ChangeState) -> Element {
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
            var waiter: OnceContinuation<Void, OnceContinuationError>?
            var dirty = false
            var cancelled = false
        }

        private let inner = Mutex(Inner())

        /// The will-set callback: wakes the waiting `next()`, or marks the
        /// state dirty so the next `next()` does not wait.
        func changed() {
            let waiter = inner.withLock { s -> OnceContinuation<Void, OnceContinuationError>? in
                guard let waiter = s.waiter else {
                    s.dirty = true
                    return nil
                }
                s.waiter = nil
                return waiter
            }
            waiter?.resume(returning: ())
        }

        /// Ends every wait now and later.
        func cancel() {
            let waiter = inner.withLock { s -> OnceContinuation<Void, OnceContinuationError>? in
                s.cancelled = true
                defer { s.waiter = nil }
                return s.waiter
            }
            waiter?.resume(returning: ())
        }

        /// Returns after the next change, at once when a change came since the
        /// last evaluation or the iteration was cancelled.
        /// Runs on the caller's isolation (nonisolated(nonsending)).
        func waitForChange() async {
            // A dropped waiter returns as a change does: the iteration evaluates again.
            _ = try? await withOnceContinuation { (continuation: OnceContinuation<Void, OnceContinuationError>) in
                let resumeNow = inner.withLock { s -> Bool in
                    if s.cancelled || s.dirty {
                        s.dirty = false
                        return true
                    }
                    s.waiter = continuation
                    return false
                }
                if resumeNow { continuation.resume(returning: ()) }
            }
        }
    }
}

/// A stream value that is emitted on every re-evaluation, equal to the last
/// one or not: the explicit trigger (I1) for a consumer that must run again
/// when an input changed but the value did not (a remount on reinstall of
/// the same version, a refresh after a daemon restart), or whose own apply
/// path can move its view off the last emitted value (it then compares
/// against what it applied, not against what the stream emitted last).
///
///     for await state in ObservationStream({ ObservationTrigger(model.state) }) { apply(state.value) }
public struct ObservationTrigger<Value: Sendable>: Sendable {
    public let value: Value
    public init(_ value: Value) { self.value = value }
}

/// DEBUG opt-in to the system-iterator path (`CMUX_NEXT_DEBUG_NATIVE_OBSERVATIONS=1`), for its fix.
struct ObservationStreamNativeOptIn {
    static let enabled: Bool = {
        #if DEBUG
        // SAFETY: getenv returns the environment's own NUL-terminated value or NULL, copied at once into a String
        // here, before this one-time read returns.
        guard let raw = unsafe getenv("CMUX_NEXT_DEBUG_NATIVE_OBSERVATIONS") else { return false }
        return unsafe String(cString: raw) == "1"
        #else
        return false
        #endif
    }()
}
