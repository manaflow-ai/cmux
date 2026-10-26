/// The app's main-thread deadlines on one sleep, and the next-fire registry (plans/cmux-next/chrome-parity/
/// p06-scheduler.md, section E and task 011).
///
/// Chromium keeps every delayed task of a thread in one wake-up queue and sleeps once, until the earliest
/// (`WakeUpQueue`, base/task/sequence_manager/wake_up_queue.h; `ThreadControllerWithMessagePumpImpl::DoWork` returns
/// the next delayed run time to the pump). This type does the same for ``MainDeadline``s: one sleep on the injected
/// clock, armed for the earliest planned fire with that fire's tolerance, re-armed only when the earliest changes,
/// and none at all while nothing is pending. A wake hands every deadline due by then to its ``MainDeadline``, which
/// posts its action on ``work`` in its class: the wake itself runs no deadline's work.
///
/// The registry side: ``nextFire`` is the time left until the earliest pending fire, ``nextFireNanos`` the same
/// instant in `CLOCK_UPTIME_RAW` nanoseconds (on ``uptime``), and ``onNextFireChange`` is called each time that
/// instant changes. Idle periods end before the next deadline with them (IdleScheduler, task 005), as Blink's
/// `IdleHelper` ends a long idle period before the next delayed task.
///
/// The composition root makes one and passes it to every ``MainDeadline``:
///
/// ```swift
/// let deadlines = MainDeadlineScheduler(work: mainWork)
/// let refresh = MainDeadline(owner: "Cloud.poll", workClass: .background, alignment: .whenHidden(window),
///                            scheduler: deadlines)
/// refresh.start(every: .seconds(30)) { cloud.poll() }
/// ```
@MainActor
public final class MainDeadlineScheduler {
    /// The `WakeupLedger` owner of the scheduler's own wakes (reason `fire`); each deadline that fires is also
    /// recorded under its owner (reason `deadline`).
    public static let ledgerOwner = "MainDeadline"

    /// Where deadline actions are posted, each in its deadline's class.
    public let work: MainWorkScheduler
    /// Called after ``nextFire`` moves to another instant: a deadline was planned, cancelled or fired.
    public var onNextFireChange: (@MainActor () -> Void)?

    private let timeline: DeadlineTimeline
    private let uptime: VisibilityNode.Uptime
    private let ledger: WakeupLedger
    private let isCaptured: @MainActor (VisibilityNode) -> Bool
    private var entries: [UInt64: Entry] = [:]
    private var nextID: UInt64 = 0
    private var armed: Armed?
    private var armedGeneration: UInt64 = 0
    /// The fire last reported through ``onNextFireChange``.
    private var reportedFire: Duration?
    /// Each node's last wake under ``TimerAlignment/Wake/Rule/intensive``, Blink's per-page wake-up budget pool.
    private var intensiveWakes: [ObjectIdentifier: IntensiveWake] = [:]
    /// The entry count at which released nodes' entries are dropped, doubled after each pass.
    private var compactAt = 16

    private struct Entry {
        let owner: String
        var wake: TimerAlignment.Wake
        /// The plan of the deadline this wake is for (``MainDeadline``'s generation).
        let generation: UInt64
        /// Weak: a released deadline's entry is dropped at the next re-arm or at its wake, unrun.
        weak var deadline: MainDeadline?
        weak var node: VisibilityNode?
    }

    private struct Armed {
        let fire: Duration
        let tolerance: Duration
        let generation: UInt64
        let sleep: Task<Void, Never>
    }

    private struct IntensiveWake {
        weak var node: VisibilityNode?
        var last: Duration
    }

    /// - Parameters:
    ///   - work: The app's one main-thread scheduler: deadline actions are posted on it.
    ///   - clock: The clock the sleep runs on (tests inject a ``ManualClock``-like clock).
    ///   - uptime: The clock of the visibility tree, for ``VisibilityNode/hiddenSince`` (the app: the system
    ///     uptime, as its nodes'), and the base of ``nextFireNanos``.
    ///   - ledger: Where each wake and each deadline that fires are counted (`debug.wakeups`).
    ///   - isCaptured: Whether a capture vote that does not stay hidden holds a node (task 211 wires it to the
    ///     node's votes; until then nothing is captured).
    public init(work: MainWorkScheduler, clock: any Clock<Duration> = ContinuousClock(),
                uptime: @escaping VisibilityNode.Uptime = VisibilityNode.systemUptime, ledger: WakeupLedger = .shared,
                isCaptured: @escaping @MainActor (VisibilityNode) -> Bool = { _ in false }) {
        self.work = work
        timeline = DeadlineTimeline(clock)
        self.uptime = uptime
        self.ledger = ledger
        self.isCaptured = isCaptured
    }

    /// The deadlines waiting for their wake.
    public var pendingCount: Int { entries.count }

    /// Whether a sleep is armed (false whenever nothing is pending).
    public var isArmed: Bool { armed != nil }

    /// The time left until the earliest pending fire (zero once it is due); nil when nothing is pending.
    public var nextFire: Duration? {
        guard let armed else { return nil }
        return max(armed.fire - timeline.now(), .zero)
    }

    /// The earliest pending fire in `CLOCK_UPTIME_RAW` nanoseconds on ``uptime``; nil when nothing is pending.
    public var nextFireNanos: UInt64? {
        guard let nextFire else { return nil }
        return (uptime() + nextFire).nanosecondCount
    }

    // MARK: MainDeadline's side

    /// Now, on the timeline every wake is planned on.
    var now: Duration { timeline.now() }

    /// The wake of a deadline due at `due` under `alignment`.
    func wake(_ alignment: TimerAlignment, due: Duration, repeating: Bool) -> TimerAlignment.Wake {
        let rule = alignment.rule(delay: due - now, repeating: repeating, uptime: uptime(), isCaptured: isCaptured)
        var last: Duration?
        if rule == .intensive, let node = alignment.node { last = lastIntensiveWake(node) }
        return TimerAlignment.Wake(rule: rule, due: due, lastIntensiveWake: last)
    }

    /// Adds `deadline`'s wake: on the wake at or after `wake.fire`, ``MainDeadline/wakeDidFire(_:)`` gets
    /// `generation`. Returns its entry for ``replan(_:wake:)`` and ``remove(_:)``.
    func insert(_ deadline: MainDeadline, generation: UInt64, wake: TimerAlignment.Wake) -> UInt64 {
        nextID &+= 1
        entries[nextID] = Entry(owner: deadline.owner, wake: wake, generation: generation, deadline: deadline,
                                node: deadline.alignment.node)
        rearm()
        return nextID
    }

    /// Moves a pending deadline to a new wake (its node's visibility changed).
    func replan(_ entry: UInt64, wake: TimerAlignment.Wake) {
        guard entries[entry] != nil else { return }
        entries[entry]?.wake = wake
        rearm()
    }

    /// Drops a pending deadline; the sleep follows the new earliest, or stops.
    func remove(_ entry: UInt64) {
        guard entries.removeValue(forKey: entry) != nil else { return }
        rearm()
    }

    // MARK: Internals

    private func lastIntensiveWake(_ node: VisibilityNode) -> Duration? {
        guard let wake = intensiveWakes[ObjectIdentifier(node)], wake.node === node else { return nil }
        return wake.last
    }

    private func noteIntensiveWake(_ node: VisibilityNode, at instant: Duration) {
        if intensiveWakes.count >= compactAt {
            intensiveWakes = intensiveWakes.filter { $0.value.node != nil }
            compactAt = max(16, 2 * intensiveWakes.count)
        }
        intensiveWakes[ObjectIdentifier(node)] = IntensiveWake(node: node, last: instant)
    }

    /// Arms the one sleep for the earliest fire (with the smallest tolerance of the deadlines that share it), keeps
    /// it when it already waits for that instant, or stops it when nothing is pending. Entries of released
    /// deadlines are dropped here.
    private func rearm() {
        var earliest: (fire: Duration, tolerance: Duration)?
        var released: [UInt64] = []
        for (id, entry) in entries {
            guard entry.deadline != nil else {
                released.append(id)
                continue
            }
            let wake = entry.wake
            if let current = earliest, current.fire < wake.fire { continue }
            if let current = earliest, current.fire == wake.fire {
                earliest = (wake.fire, min(current.tolerance, wake.tolerance))
            } else {
                earliest = (wake.fire, wake.tolerance)
            }
        }
        for id in released { entries[id] = nil }
        if let earliest {
            if let armed, armed.fire == earliest.fire, armed.tolerance <= earliest.tolerance {
                // Already waiting for this instant, at least as strictly.
            } else {
                armed?.sleep.cancel()
                armed = arm(at: earliest.fire, tolerance: earliest.tolerance)
            }
        } else if let armed {
            armed.sleep.cancel()
            self.armed = nil
        }
        if earliest?.fire != reportedFire {
            reportedFire = earliest?.fire
            onNextFireChange?()
        }
    }

    private func arm(at fire: Duration, tolerance: Duration) -> Armed {
        armedGeneration &+= 1
        let generation = armedGeneration
        let timeline = timeline
        // task-owner: the scheduler's one sleep; cancelled when the earliest fire moves, and it holds self weakly.
        let sleep = Task { [weak self] in
            do { try await timeline.sleep(fire, tolerance) } catch { return }
            self?.wakeUp(generation)
        }
        return Armed(fire: fire, tolerance: tolerance, generation: generation, sleep: sleep)
    }

    /// The sleep ended: every deadline due by now fires, in fire order, then the sleep is armed for what is left.
    /// "Due" is judged at the time read here, as `LazyNow` in `TaskQueueImpl::MoveReadyDelayedTasksToWorkQueue`.
    private func wakeUp(_ generation: UInt64) {
        guard armed?.generation == generation else { return }
        armed = nil
        let instant = timeline.now()
        ledger.record(Self.ledgerOwner, reason: "fire")
        let due = entries.filter { $0.value.wake.fire <= instant }
            .sorted { ($0.value.wake.fire, $0.key) < ($1.value.wake.fire, $1.key) }
        var owners = Set<String>()
        for (id, entry) in due {
            guard entries.removeValue(forKey: id) != nil, let deadline = entry.deadline else { continue }
            if entry.wake.rule == .intensive, let node = entry.node { noteIntensiveWake(node, at: instant) }
            if owners.insert(entry.owner).inserted { ledger.record(entry.owner, reason: "deadline") }
            deadline.wakeDidFire(entry.generation)
        }
        rearm()
    }
}

/// A clock seen as offsets from the moment the scheduler was made, so a wake's grid is plain `Duration`
/// arithmetic on any injected clock.
private struct DeadlineTimeline: Sendable {
    let now: @Sendable () -> Duration
    let sleep: @Sendable (_ offset: Duration, _ tolerance: Duration) async throws -> Void

    init<C: Clock>(_ clock: C) where C.Duration == Duration {
        let origin = clock.now
        now = { origin.duration(to: clock.now) }
        sleep = { offset, tolerance in try await clock.sleep(until: origin.advanced(by: offset), tolerance: tolerance) }
    }
}
