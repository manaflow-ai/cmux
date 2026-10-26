public import CmuxNextCompat
public import CmuxNextInputCore
public import CmuxNextWakeups

/// The owner of the targets' content (the browser hibernation in the app): says which target is cold and
/// runs the cheap prewarm kinds (hibernated page restore in the background, frozen page thaw).
/// A prewarm writes nothing to the daemon, attaches no terminal and changes nothing on screen.
/// The service holds its warmer weakly, so the warmer may own the service.
public protocol IntentPrewarmWarming<Target>: AnyObject {
    associatedtype Target: Hashable & Sendable

    /// `target`'s content is hibernated or frozen, so a prewarm has work to do.
    func isCold(_ target: Target) -> Bool
    /// Starts the cheap kinds for `target`.
    func startPrewarm(_ target: Target, trigger: IntentPrewarmTrigger)
    /// Drops `target`'s prewarm, which the FIFO evicted or memory pressure cancelled before it was used.
    func cancelPrewarm(_ target: Target)
}

/// Intent prewarm for the sidebar's rows and the tab strip's tabs.
///
/// Pointer down (p04-input-042): a press on a target that commits only on its release (a workspace row
/// with `sidebar.multiView`, a row of a multi-selection) reaches ``pointerPressed(on:)`` with that target,
/// whose prewarm starts at once when it is cold; the press-to-release time is its head start. This is
/// Chrome's conservative eagerness, which starts on pointerdown
/// (third_party/blink/renderer/core/html/anchor_element_interaction_tracker.cc, `OnPointerEvent`). A sidebar
/// press that switches on the press passes nil; the strip's tabs and the palette's rows also commit on the
/// press, so their commit (``committed(_:)``) ends the dwell and there is no release to prewarm ahead of.
/// A press prewarm kept after a release elsewhere stays until evicted or used; the warmer adds no hold,
/// so its page sleeps again by the hibernation's own grace.
///
/// Hover dwell (p04-input-043): a hover delivery (``pointerHovered(_:)``, from the sidebar's and the tab
/// strip's hover change) that reaches a cold target arms the service's one ``MainDeadline``; after ``dwell``
/// the target's prewarm starts. A delivery on another target re-arms it, one on nothing, a press or a commit
/// cancels it, so the timer is pending only while the pointer rests on a cold target. Chrome's hover
/// heuristic is the same one-shot timer, restarted per anchor and stopped on pointerout
/// (anchor_element_interaction_tracker.cc).
///
/// The held prewarms are an ``IntentPrewarmQueue`` (FIFO of 2, oldest cancelled).
///
/// Nothing starts in Low Power Mode on battery or at memory pressure warning or worse
/// (`PreloadingEligibility::kBatterySaverEnabled`, `kMemoryPressure`); critical pressure also cancels the
/// held prewarms, as `PrerenderHostRegistry::OnMemoryPressure` cancels every host
/// (`kMemoryPressureAfterTriggered`).
@MainActor
public final class IntentPrewarmService<Target: Hashable & Sendable> {
    /// How long the pointer rests on a target before its prewarm starts (Chrome's moderate eagerness).
    public let dwell: Duration
    /// The triggers this service starts prewarms for: `hoverDwell` with `intentPrewarmHover`, `pointerDown`
    /// with `intentPrewarmPress`. A delivery for another trigger starts nothing.
    public let enabledTriggers: Set<IntentPrewarmTrigger>
    /// The held prewarms.
    public private(set) var queue = IntentPrewarmQueue<Target>()
    /// The target under the pointer, from the last hover delivery; nil on nothing.
    public private(set) var restingTarget: Target?
    /// What the service did.
    public private(set) var counters = IntentPrewarmCounters()
    /// Energy Saver's power inputs, pushed by the composition root. Entering Low Power Mode on battery
    /// cancels the dwell; the held prewarms stay until evicted or used.
    public var power: IntentPrewarmPower {
        didSet { if power.savesBattery { dwellTimer.cancel() } }
    }

    private weak var warmer: (any IntentPrewarmWarming<Target>)?
    private let memoryPressure: MemoryPressureEvents
    private let dwellTimer: MainDeadline
    private var pressureObservation: MainActorHandlerRegistration<MemoryPressureLevel>?

    /// - Parameters:
    ///   - warmer: Says which target is cold and runs its prewarm; held weakly (gone: nothing is cold).
    ///   - memoryPressure: The app's one memory pressure source.
    ///   - dwellTimer: The service's one deadline: a background-class `MainDeadline` on the app's deadline
    ///     scheduler (a prewarm is work nobody sees yet, so it waits behind input and visible work).
    ///   - dwell: The rest before a hover prewarm; the `intentPrewarmHover` feature's `dwell` param.
    ///   - triggers: The triggers to start prewarms for (both by default).
    ///   - power: The power inputs now.
    public init(warmer: any IntentPrewarmWarming<Target>, memoryPressure: MemoryPressureEvents, dwellTimer: MainDeadline,
                dwell: Duration = .milliseconds(200), triggers: Set<IntentPrewarmTrigger> = Set(IntentPrewarmTrigger.allCases),
                power: IntentPrewarmPower = IntentPrewarmPower()) {
        self.warmer = warmer
        self.memoryPressure = memoryPressure
        self.dwellTimer = dwellTimer
        self.dwell = dwell
        enabledTriggers = triggers
        self.power = power
        pressureObservation = memoryPressure.observe { [weak self] level in self?.memoryPressureDidChange(level) }
    }

    // The timer and the pressure registration end themselves when released, on any thread.
    nonisolated deinit {}

    /// The dwell's deadline is pending (the pointer rests on a cold target).
    public var isDwelling: Bool { dwellTimer.isScheduled }

    /// A hover delivery: the pointer is on `target`, or on nothing. Another target restarts the dwell (when
    /// it is cold and not held); the same target keeps it, so repeated deliveries on one row cost a compare.
    public func pointerHovered(_ target: Target?) { // perf-hot: 5us intent-prewarm-hover (each hover target change)
        guard target != restingTarget, enabledTriggers.contains(.hoverDwell) else { return }
        restingTarget = target
        dwellTimer.cancel()
        guard let target, !queue.contains(target), let warmer, warmer.isCold(target), admits() else { return }
        dwellTimer.schedule(after: dwell) { [weak self] in self?.dwellElapsed() }
    }

    /// A press: the dwell stops and does not restart until the pointer reaches another target.
    /// `target` is what the press commits on its release, nil when it commits on the press or on nothing.
    /// With `pointerDown` enabled, a cold `target` not held yet is prewarmed now (``prewarm(_:trigger:)``:
    /// the FIFO, power and pressure rules hold).
    public func pointerPressed(on target: Target? = nil) {
        dwellTimer.cancel()
        guard let target, enabledTriggers.contains(.pointerDown), warmer?.isCold(target) == true else { return }
        prewarm(target, trigger: .pointerDown)
    }

    /// Starts `target`'s prewarm unless it is held already, evicting the oldest past the queue's limit.
    /// Nothing starts in Low Power Mode on battery or at memory pressure warning or worse.
    public func prewarm(_ target: Target, trigger: IntentPrewarmTrigger) {
        guard !queue.contains(target), let warmer, admits() else { return }
        if let evicted = queue.admit(target, by: trigger) {
            warmer.cancelPrewarm(evicted)
            counters.evicted += 1
        }
        counters.started[trigger, default: 0] += 1
        warmer.startPrewarm(target, trigger: trigger)
    }

    /// `target` committed: its prewarm, if held, was used and leaves the FIFO without a cancel.
    public func committed(_ target: Target) {
        if restingTarget == target { dwellTimer.cancel() }
        guard let trigger = queue.remove(target) else { return }
        counters.used += 1
        counters.hits[trigger, default: 0] += 1
    }

    /// Starts the counters over (`debug.input` action `reset`); the held prewarms stay.
    public func resetCounters() {
        counters = IntentPrewarmCounters()
    }

    /// `target`'s content went (its tab closed): it leaves the FIFO without a cancel or a use.
    public func forget(_ target: Target) {
        if restingTarget == target {
            restingTarget = nil
            dwellTimer.cancel()
        }
        queue.remove(target)
    }

    /// The dwell's deadline: every target change cancels it, so `restingTarget` is the target it was armed on.
    private func dwellElapsed() {
        guard let target = restingTarget, warmer?.isCold(target) == true else { return }
        prewarm(target, trigger: .hoverDwell)
    }

    /// Whether a prewarm may start now; counts the skip when not.
    private func admits() -> Bool {
        if power.savesBattery {
            counters.skippedForPower += 1
            return false
        }
        if memoryPressure.currentLevel != .normal {
            counters.skippedForPressure += 1
            return false
        }
        return true
    }

    private func memoryPressureDidChange(_ level: MemoryPressureLevel) {
        guard level != .normal else { return }
        dwellTimer.cancel()
        guard level == .critical else { return }
        let dropped = queue.removeAll()
        counters.cancelledByPressure += dropped.count
        for target in dropped { warmer?.cancelPrewarm(target) }
    }
}
