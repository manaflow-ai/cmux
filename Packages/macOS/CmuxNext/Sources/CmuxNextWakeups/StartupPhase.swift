/// The app's startup phases (plans/cmux-next/chrome-parity/p06-scheduler.md, section A,
/// "Startup phases"): what may run on the main thread while the first window is still coming.
///
/// - ``Phase/launching``: input, frame, user-blocking, visible and automation work run;
///   background and idle work are held.
/// - ``Phase/revealed``: at the first frame (``noteFirstFrame()``), at once for a hidden or
///   windowless launch (``noteLaunch(_:)``), or at the reveal deadline (1.5 s) when no frame
///   comes. Background work opens.
/// - ``Phase/settled``: when every ``Reference`` is done (first frame, first daemon snapshot,
///   session restore, the visible page load-idle), or at the failsafe (10 s after launch). Idle
///   work opens.
///
/// Chrome's model: `chrome/browser/after_startup_task_utils.cc` queues after-startup tasks and
/// posts them in order when its `StartupObserver` sees first paint and the visible page load
/// (with a 3 min failsafe), and `base/task/thread_pool/thread_pool_instance.h`
/// (`BeginBestEffortFence`/`EndBestEffortFence`) holds best-effort tasks until then. cmux's
/// failsafe is 10 s: no network-bound restore is on its critical path.
///
/// Held work is not run by this type: a poster asks ``whenReached(_:_:)`` to run its enqueue at
/// the phase that opens its class (``MainWorkClass/startupOpening``, ``Phase/settled`` for idle),
/// so held bodies reach their class queues in post order at the phase change.
///
/// ```swift
/// // The composition root (one per app, passed by init; no shared instance):
/// let startup = StartupPhase()
/// startup.noteLaunch(NSApp.isHidden ? .hidden : .window)
/// // A background post:
/// startup.whenReached(MainWorkClass.background.startupOpening) { queue.enqueue(body) }
/// // LaunchReveal's first frame, the daemon's first snapshot:
/// startup.noteFirstFrame()
/// startup.markDone(.firstSnapshot)
/// ```
///
/// Its one timer is an unposted ``DemandTimer`` (the reveal deadline, then the settle failsafe):
/// it never waits behind the classes it opens, and a settled phase has no timer.
@MainActor
public final class StartupPhase {
    /// One startup phase, in launch order.
    public enum Phase: Int, Sendable, Comparable, CaseIterable, CustomStringConvertible {
        case launching
        case revealed
        case settled

        public static func < (lhs: Phase, rhs: Phase) -> Bool { lhs.rawValue < rhs.rawValue }

        public var description: String {
            switch self {
            case .launching: "launching"
            case .revealed: "revealed"
            case .settled: "settled"
            }
        }
    }

    /// How the app launched, known when it finished launching.
    public enum Presentation: Sendable {
        /// A window is coming: reveal at its first frame or at the deadline.
        case window
        /// Launched hidden (`open -g`, a login item): nobody waits for a frame, reveal at once.
        case hidden
        /// No window to show (nothing restored, a background-only launch): reveal at once.
        case noWindow
    }

    /// What settles startup: each is done once (``markDone(_:)``); settled when all are.
    public enum Reference: Sendable, CaseIterable, CustomStringConvertible {
        /// The first window's first frame (``noteFirstFrame()``).
        case firstFrame
        /// The daemon's first snapshot applied to the store.
        case firstSnapshot
        /// Session restore finished.
        case restoreDone
        /// The visible Chromium page reached load-idle, or no page is visible.
        case visiblePageIdle

        public var description: String {
            switch self {
            case .firstFrame: "firstFrame"
            case .firstSnapshot: "firstSnapshot"
            case .restoreDone: "restoreDone"
            case .visiblePageIdle: "visiblePageIdle"
            }
        }
    }

    /// What revealed the app.
    public enum RevealCause: Sendable, Equatable {
        case firstFrame
        case deadline
        case hidden
        case noWindow
    }

    /// What settled startup.
    public enum SettleCause: Sendable, Equatable {
        case references
        case failsafe
    }

    /// The phase deadlines, both measured from the phase's creation (the app's launch).
    public struct Timing: Sendable {
        /// The latest reveal when no first frame comes.
        public var revealDeadline: Duration
        /// The latest settle when a reference never comes.
        public var settleFailsafe: Duration

        public init(revealDeadline: Duration = .milliseconds(1_500), settleFailsafe: Duration = .seconds(10)) {
            self.revealDeadline = revealDeadline
            self.settleFailsafe = settleFailsafe
        }
    }

    /// Work that was awaited before the phase that opens its class: the awaiting caller would
    /// wait for the reveal or the settle, not for its work.
    public struct HeldAwait: Sendable, CustomStringConvertible {
        /// The held class (`background` or `idle`).
        public let work: String
        public let owner: String
        public let phase: Phase
        public let file: String
        public let line: UInt

        public var description: String { "\(work) work of \(owner) awaited while \(phase) (\(file):\(line))" }
    }

    /// The phase now.
    public private(set) var phase: Phase
    /// What revealed the app (nil while launching, and for ``settled()``).
    public private(set) var revealCause: RevealCause?
    /// What settled startup (nil before settled, and for ``settled()``).
    public private(set) var settleCause: SettleCause?
    /// The references not done yet.
    public private(set) var pendingReferences: Set<Reference>

    private let timing: Timing
    /// Time since the phase was made, on the injected clock.
    private let elapsed: () -> Duration
    private let timer: DemandTimer
    private let onHeldAwait: @MainActor (HeldAwait) -> Void
    private var revealWaiters: [@MainActor () -> Void] = []
    private var settleWaiters: [@MainActor () -> Void] = []
    /// True while the reveal runs its held actions: a reference one of them marks done settles
    /// only after the last of them, so held background work runs before held idle work.
    private var releasingReveal = false

    /// A launching phase with its reveal deadline armed.
    ///
    /// - Parameters:
    ///   - clock: The deadlines' clock (tests inject a manual clock).
    ///   - ledger: Where the deadline's wakeups are recorded.
    ///   - timing: The reveal deadline and the settle failsafe.
    ///   - onHeldAwait: Called when held work is awaited while its class is held; the default is
    ///     a Debug assertion (``assertNotHeld(_:)``).
    public init(clock: any Clock<Duration> = ContinuousClock(), ledger: WakeupLedger = .shared, timing: Timing = Timing(),
                onHeldAwait: @escaping @MainActor (HeldAwait) -> Void = StartupPhase.assertNotHeld) {
        self.timing = timing
        self.onHeldAwait = onHeldAwait
        elapsed = StartupPhase.stopwatch(clock)
        timer = DemandTimer(owner: "StartupPhase", clock: clock, ledger: ledger)
        phase = .launching
        pendingReferences = Set(Reference.allCases)
        timer.schedule(after: timing.revealDeadline) { @MainActor [weak self] in self?.deadlinePassed() }
    }

    private init(settledWith ledger: WakeupLedger) {
        timing = Timing()
        onHeldAwait = StartupPhase.assertNotHeld
        elapsed = { .zero }
        timer = DemandTimer(owner: "StartupPhase", ledger: ledger)
        phase = .settled
        pendingReferences = []
    }

    /// A phase that is already settled, with no timer: schedulers whose work never waits for a
    /// launch (tests, previews, a scheduler made after launch).
    public static func settled(ledger: WakeupLedger = WakeupLedger()) -> StartupPhase {
        StartupPhase(settledWith: ledger)
    }

    /// Whether `workClass` may run now. Only background waits for the reveal; input, frame,
    /// visible and automation work are never held.
    public func admits(_ workClass: MainWorkClass) -> Bool { phase >= workClass.startupOpening }

    /// Whether idle work may run now (only once settled).
    public var admitsIdle: Bool { phase == .settled }

    /// Runs `action` now when the phase is `target` or later; else holds it and runs it at the
    /// change to `target`, after the actions held before it.
    public func whenReached(_ target: Phase, _ action: @escaping @MainActor () -> Void) {
        guard phase < target else { return action() }
        switch target {
        case .launching: action()
        case .revealed: revealWaiters.append(action)
        case .settled: settleWaiters.append(action)
        }
    }

    /// Records how the app launched: a hidden or windowless launch reveals at once and has no
    /// first frame to wait for.
    public func noteLaunch(_ presentation: Presentation) {
        switch presentation {
        case .window: return
        case .hidden: reveal(.hidden)
        case .noWindow: reveal(.noWindow)
        }
    }

    /// The first window's first frame: reveals, and is the ``Reference/firstFrame`` reference.
    public func noteFirstFrame() {
        guard phase == .launching else { return markDone(.firstFrame) }
        reveal(.firstFrame)
    }

    /// Marks one settle reference done (again is a no-op); the last one settles a revealed app.
    public func markDone(_ reference: Reference) {
        guard pendingReferences.remove(reference) != nil else { return }
        if pendingReferences.isEmpty, phase == .revealed, !releasingReveal { settle(.references) }
    }

    /// Reports a caller that awaits `workClass` work while that class is held (a Debug assertion
    /// by default): `await mainWork.apply(.background, ...)` in launching waits for the reveal.
    public func checkAwait(_ workClass: MainWorkClass, owner: String, file: StaticString = #fileID, line: UInt = #line) {
        guard !admits(workClass) else { return }
        onHeldAwait(HeldAwait(work: workClass.description, owner: owner, phase: phase, file: "\(file)", line: line))
    }

    /// Reports a caller that awaits idle work before startup settled (a Debug assertion by
    /// default).
    public func checkIdleAwait(owner: String, file: StaticString = #fileID, line: UInt = #line) {
        guard !admitsIdle else { return }
        onHeldAwait(HeldAwait(work: "idle", owner: owner, phase: phase, file: "\(file)", line: line))
    }

    /// The default held-await report: an assertion in Debug builds, nothing in Release.
    public nonisolated static func assertNotHeld(_ wait: HeldAwait) {
        assertionFailure("startup: \(wait)")
    }

    private func deadlinePassed() {
        switch phase {
        case .launching: reveal(.deadline)
        case .revealed: settle(.failsafe)
        case .settled: return
        }
    }

    private func reveal(_ cause: RevealCause) {
        guard phase == .launching else { return }
        phase = .revealed
        revealCause = cause
        // Only the deadline leaves a frame to wait for: a frame, a hidden or a windowless launch does not.
        if cause != .deadline { pendingReferences.remove(.firstFrame) }
        timer.cancel()
        let held = revealWaiters
        revealWaiters = []
        releasingReveal = true
        for action in held { action() }
        releasingReveal = false
        let left = timing.settleFailsafe - elapsed()
        if pendingReferences.isEmpty || left <= .zero {
            settle(pendingReferences.isEmpty ? .references : .failsafe)
        } else {
            timer.schedule(after: left) { @MainActor [weak self] in self?.deadlinePassed() }
        }
    }

    private func settle(_ cause: SettleCause) {
        guard phase == .revealed else { return }
        phase = .settled
        settleCause = cause
        timer.cancel()
        let held = settleWaiters
        settleWaiters = []
        for action in held { action() }
    }

    /// Time since now on `clock` (opens the existential so its instants can be compared).
    private nonisolated static func stopwatch<C: Clock<Duration>>(_ clock: C) -> () -> Duration {
        let start = clock.now
        return { start.duration(to: clock.now) }
    }
}

extension MainWorkClass {
    /// The startup phase that opens this class: input, frame, visible and automation work run
    /// while launching, and background waits for the reveal. Idle work (not a class) waits for
    /// the settle.
    public var startupOpening: StartupPhase.Phase { self == .background ? .revealed : .launching }
}
