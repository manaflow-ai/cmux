public import CmuxNextWakeups
import CmuxNextCompat

/// The `mutation_id`s this app sent recently, each with the cause of the scope that sent it
/// (``DaemonCommandScope/cause``), so the echo of a person's own change applies as `person` and
/// the echo of a socket-run change as `automation` (plans/cmux-next/chrome-parity/p06-scheduler.md,
/// "Person cause, app side"). Nothing new goes on the wire: the app matches the ids it chose.
///
/// Chrome credits work to a person's input the same way, for a fixed span after it: transient user
/// activation expires after its lifespan (`third_party/blink/common/frame/user_activation_state.cc`,
/// `kActivationLifespan`). An entry here lives 2 s after it was recorded (``lifetime``); past
/// ``capacity`` live entries the oldest goes first.
///
/// The connection records on its actor and looks up on its reader thread, so the table sits in a
/// `Mutex` held only for one dictionary operation. Cause is for scheduling only; authorization
/// code never reads it.
public final class MutationCauseLedger: Sendable {
    /// How long an id names its cause after it was recorded.
    public static let defaultLifetime: Duration = .seconds(2)
    /// The most ids held at once.
    public static let defaultCapacity = 512

    private struct Entry {
        var cause: ObservationCause
        var recordedAt: Duration
    }

    private struct State {
        var causes: [String: Entry] = [:]
        /// Ids in recording order; `head` is the oldest one still held.
        var order: [String] = []
        var head = 0
    }

    private let state = Mutex(State())
    private let lifetime: Duration
    private let capacity: Int
    private let elapsed: @Sendable () -> Duration

    /// A ledger whose entries age on the continuous clock.
    public convenience init(lifetime: Duration = defaultLifetime, capacity: Int = defaultCapacity) {
        self.init(clock: ContinuousClock(), lifetime: lifetime, capacity: capacity)
    }

    /// - Parameters:
    ///   - clock: The clock entries age on (an injected test clock moves only when the test says).
    ///   - lifetime: How long an id names its cause.
    ///   - capacity: The most ids held at once.
    public init<C: Clock>(clock: C, lifetime: Duration = defaultLifetime, capacity: Int = defaultCapacity)
        where C.Duration == Duration {
        let start = clock.now
        elapsed = { start.duration(to: clock.now) }
        self.lifetime = lifetime
        self.capacity = max(capacity, 1)
    }

    /// Records that `mutationID` was sent with `cause`.
    public func record(_ mutationID: String, cause: ObservationCause) {
        let now = elapsed()
        state.withLock { state in
            evict(&state, now: now, room: 1)
            if state.causes.updateValue(Entry(cause: cause, recordedAt: now), forKey: mutationID) == nil {
                state.order.append(mutationID)
            }
        }
    }

    /// The cause `mutationID` was recorded with, or nil when it was not recorded or expired.
    public func cause(of mutationID: String) -> ObservationCause? {
        let now = elapsed()
        return state.withLock { state in
            guard let entry = state.causes[mutationID], now - entry.recordedAt < lifetime else { return nil }
            return entry.cause
        }
    }

    /// Ids held now, expired ones included until the next record drops them (tests, diagnostics).
    var count: Int { state.withLock { $0.causes.count } }

    /// Drops expired ids, then the oldest until `room` more fit. O(1) amortized per recorded id.
    private func evict(_ state: inout State, now: Duration, room: Int) {
        while state.head < state.order.count {
            let id = state.order[state.head]
            if let entry = state.causes[id], now - entry.recordedAt < lifetime, state.causes.count + room <= capacity { break }
            state.causes[id] = nil
            state.head += 1
        }
        if state.head == state.order.count {
            state.order.removeAll(keepingCapacity: true)
            state.head = 0
        } else if state.head >= 64, state.head * 2 >= state.order.count {
            state.order.removeFirst(state.head)
            state.head = 0
        }
    }
}
