import Observation

/// The tracking core of ``VisibleObservation`` and ``FrameObservation``: a one-shot
/// `withObservationTracking` of `read`, the cancel signal that drops an armed tracking, the stale
/// generation check, the ledger's armed counts, and the cause of the pending change
/// (``ObservationCauses/currentCause`` at each will-set, raised to the highest one seen). The
/// observation that owns it decides only when its flush runs (its ``ObservationTrackerClient``).
///
/// The first change of anything `read` read marks it dirty with the current cause and tells the
/// client. A person cause also queues it for the input-response pass
/// (``ObservationCauses/flushPersonCaused()``), which asks the client to apply before the input's
/// commit. Until the cause is person, it re-arms in that turn (one read), so a later change by the
/// person raises the cause; once it is person, later changes cost nothing until the flush.
@MainActor
final class ObservationTracker<Value> {
    /// The observation that owns this tracker, weakly.
    weak var client: (any ObservationTrackerClient)?
    /// The owner's counts in ``MainWorkScheduler/observations`` (`debug.observations`).
    let counts: ObservationLedger.Owner
    /// A tracking is registered and has not fired.
    private(set) var isArmed = false
    /// The highest cause of the changes since the last ``clean()``; nil while nothing is pending.
    private(set) var dirtyCause: ObservationCause?
    /// Tracking callbacks received, stale ones included.
    private(set) var callbacks = 0

    private let causes: ObservationCauses
    private let read: @MainActor () -> Value
    /// Written to fire the armed tracking, so the registrar drops it.
    private let signal = ObservationCancelSignal()
    /// The armed tracking's generation; a callback of an older one is stale.
    private var generation: UInt64 = 0
    /// The pass's entry for the pending person-caused flush (``ObservationCauses/enqueuePerson(_:)``).
    private var personTicket: UInt64 = 0

    init(counts: ObservationLedger.Owner, causes: ObservationCauses, read: @escaping @MainActor () -> Value) {
        self.counts = counts
        self.causes = causes
        self.read = read
    }

    // Only an armed tracking outlives the tracker. A generic main-actor class needs a nonisolated
    // deinit (the Release optimizer crashes on its isolated one, #23050), so the signal write hops
    // when released off main.
    nonisolated deinit {
        guard isArmed else { return }
        counts.disarmed()
        let signal = self.signal
        MainDelivery().run { signal.epoch &+= 1 }
    }

    /// Reads `read` with a fresh one-shot tracking.
    func track() -> Value {
        generation &+= 1
        isArmed = true
        counts.armed()
        let armedGeneration = generation, signal = self.signal, observed = self.read, causes = self.causes
        return withObservationTracking {
            _ = signal.epoch
            return observed()
        } onChange: { @Sendable [weak self] in
            MainDelivery().run { [weak self] in
                guard let self else {
                    causes.noteReleasedTrackingFire()
                    return
                }
                self.fired(armedGeneration)
            }
        }
    }

    /// Reads `read` with no tracking.
    func readUntracked() -> Value {
        read()
    }

    /// Fires the armed tracking, so the registrar drops it; its callback is stale.
    func disarm() {
        generation &+= 1
        guard isArmed else { return }
        isArmed = false
        counts.disarmed()
        signal.epoch &+= 1
    }

    /// Ends the dirty period (the flush ran or was dropped); the pass's entry goes stale.
    func clean() {
        dirtyCause = nil
    }

    private func fired(_ generation: UInt64) { // perf-hot: 0.01ms frame-tick (each observed will-set)
        callbacks += 1
        guard isArmed, generation == self.generation else { return }
        isArmed = false
        counts.disarmed()  // the tracking fired, and so is gone
        let cause = causes.currentCause
        let previous = dirtyCause
        if previous.map({ cause > $0 }) ?? true {
            dirtyCause = cause
            if cause == .person { personTicket = causes.enqueuePerson(self) }
            client?.dirtied(cause, after: previous)
        }
        // Only a higher cause can change the flush now; person is the highest.
        if dirtyCause == .person { return }
        _ = track()
        counts.evaluated()
    }

    /// `==` for an `Equatable` value, nil for any other (no dedupe).
    static func equality() -> ((Value, Value) -> Bool)? {
        guard let type = Value.self as? any Equatable.Type else { return nil }
        return equality(type)
    }

    private static func equality<E: Equatable>(_: E.Type) -> (Value, Value) -> Bool {
        { lhs, rhs in (lhs as? E) == (rhs as? E) }
    }
}

extension ObservationTracker: CausedObservation {
    func isPersonPending(ticket: UInt64) -> Bool {
        dirtyCause == .person && ticket == personTicket
    }

    func flushPersonCaused(ticket: UInt64) -> Bool {
        guard isPersonPending(ticket: ticket), let client else { return false }
        return client.flushPersonCaused()
    }
}

/// The observation an ``ObservationTracker`` serves: it schedules and runs the flush.
@MainActor
protocol ObservationTrackerClient: AnyObject {
    /// The pending flush's cause became `cause`; `previous` is the cause it had, nil when nothing
    /// was pending.
    func dirtied(_ cause: ObservationCause, after previous: ObservationCause?)
    /// Applies the person-caused flush now, in the input-response pass, and ends the dirty period
    /// (``ObservationTracker/clean()``); false when it may not apply now (cancelled, hidden or frozen).
    func flushPersonCaused() -> Bool
}

/// Read under every ``ObservationTracker`` tracking; writing it fires (and so removes) that tracking.
@MainActor @Observable
final class ObservationCancelSignal {
    var epoch: UInt64 = 0
}
