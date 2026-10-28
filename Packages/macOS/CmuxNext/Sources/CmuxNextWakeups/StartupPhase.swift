/// The app's startup phases (plans/cmux-next/chrome-parity/p06-scheduler.md, section A,
/// "Startup phases"): what may run on the main thread while the first window is still coming.
///
/// - ``Phase/launching``: input, frame, userBlocking, visible and automation work run; background
///   work is held. Off main, the launch's best-effort fence (``BackgroundWork/LaunchFence``, raised
///   in `main()` with no cap) holds posted best-effort and idle lane items, while user-visible and
///   awaited lane work runs at once.
/// - ``Phase/revealed``: at the first frame (``noteFirstFrame()``), at once for a hidden or
///   windowless launch (``noteLaunch(_:)``), or at the reveal deadline (1.5 s) when a window's
///   first frame never comes. Background work opens, and the launch order (`LaunchOrder`) lowers
///   the best-effort fence here, so its held items start in post order; nothing else lowers it.
/// - ``Phase/settled``: when every ``Reference`` is done (first frame, first daemon snapshot,
///   session restore, the visible page load-idle), or at the failsafe (10 s after launch). Work
///   held for the settle (``whenReached(_:_:)``; the idle class, task 005) opens.
///
/// Chrome's model: `chrome/browser/after_startup_task_utils.cc` queues after-startup tasks and
/// posts them in order when its `StartupObserver` sees first paint and the visible page load
/// (with a 3 min failsafe), and `base/task/thread_pool/thread_pool_instance.h`
/// (`BeginBestEffortFence`/`EndBestEffortFence`) holds best-effort tasks until then. cmux's
/// failsafe is 10 s: no network-bound restore is on its critical path.
///
/// Held work is not run by this type. Like Chrome's `QueueEnabledVoter`
/// (`content/browser/scheduler/browser_task_queues.cc`, `EnableAllExceptBestEffortQueues`), it
/// disables a class, not a post: a budgeted ``FrameClient`` of a class the phase does not admit
/// (``MainWorkClass/startupOpening``) stays off its frame scheduler, so its queued work (posts,
/// ``FrameBatchQueue`` and `FrameBatcher` batches) stays in its queue, in order, until the phase
/// change attaches the client and the next frame drains it.
///
/// ```swift
/// // The composition root (one per app, passed by init; no shared instance):
/// let startup = StartupPhase()
/// let mainWork = MainWorkScheduler(budget: budget, startup: startup)
/// startup.noteLaunch(NSApp.isHidden ? .hidden : .window)
/// // LaunchReveal's first frame, the daemon's first snapshot:
/// startup.noteFirstFrame()
/// startup.markDone(.firstSnapshot)
/// ```
///
/// Its one timer is an unposted ``DemandTimer`` (the reveal deadline, then the settle failsafe):
/// it never waits behind the classes it opens, and a settled phase has no timer. Each arm acts
/// only in the phase it was armed for: a reveal deadline whose fire was claimed just before a
/// first frame revealed the app does nothing.
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
        /// A window is coming: reveal at its first frame, or at the deadline when that frame never
        /// comes (the window never shows or never draws).
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

        /// Deadlines; the defaults are the launch's.
        public init(revealDeadline: Duration = .milliseconds(1_500), settleFailsafe: Duration = .seconds(10)) {
            self.revealDeadline = revealDeadline
            self.settleFailsafe = settleFailsafe
        }
    }

    /// Work that was awaited before the phase that opens its class: the awaiting caller would
    /// wait for the reveal or the settle, not for its work.
    public struct HeldAwait: Sendable, CustomStringConvertible {
        /// The held class.
        public let work: MainWorkClass
        /// The awaited work's owner.
        public let owner: String
        /// The phase when it was awaited.
        public let phase: Phase
        /// The awaiting file's `#fileID`.
        public let file: String
        /// The awaiting line.
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
        elapsed = clock.stopwatch()
        // timer-class-allow: the reveal deadline, an unposted scheduler timer (p06 section A)
        timer = DemandTimer(owner: "StartupPhase", clock: clock, ledger: ledger)
        phase = .launching
        pendingReferences = Set(Reference.allCases)
        timer.scheduleOnMain(after: timing.revealDeadline) { [weak self] in self?.revealDeadlinePassed() }
    }

    private init(settledWith ledger: WakeupLedger) {
        timing = Timing()
        onHeldAwait = StartupPhase.assertNotHeld
        elapsed = { .zero }
        // timer-class-allow: the settled phase's timer, never scheduled
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
    /// userBlocking, visible and automation work are never held.
    public func admits(_ workClass: MainWorkClass) -> Bool { phase >= workClass.startupOpening }

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
        onHeldAwait(HeldAwait(work: workClass, owner: owner, phase: phase, file: "\(file)", line: line))
    }

    /// The default held-await report: an assertion in Debug builds, nothing in Release.
    public nonisolated static func assertNotHeld(_ wait: HeldAwait) {
        assertionFailure("startup: \(wait)")
    }

    /// The reveal deadline's arm: reveals only a launch still launching.
    private func revealDeadlinePassed() {
        guard phase == .launching else { return }
        reveal(.deadline)
    }

    /// The failsafe's arm: settles only a revealed launch.
    private func failsafePassed() {
        guard phase == .revealed else { return }
        settle(.failsafe)
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
            timer.scheduleOnMain(after: left) { [weak self] in self?.failsafePassed() }
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
}

extension MainWorkClass {
    /// The startup phase that opens this class: input, frame, userBlocking, visible and automation
    /// work run while launching, background waits for the reveal and idle work for the settle.
    /// Exhaustive on purpose: a new class does not compile until it is mapped here.
    public var startupOpening: StartupPhase.Phase {
        switch self {
        case .input, .frame, .userBlocking, .visible, .automation: .launching
        case .background: .revealed
        case .idle: .settled
        }
    }
}
