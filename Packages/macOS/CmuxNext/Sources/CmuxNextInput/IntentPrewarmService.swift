public import CmuxNextCompat
public import CmuxNextInputCore
public import CmuxNextWakeups

/// The owner of the targets' content (the browser hibernation in the app): says which target is cold and
/// runs the cheap prewarm kinds (frozen page thaw; for a hibernated page, its cover decoded off the main
/// thread, its target size, then its restore in the background). A prewarm writes nothing to the daemon,
/// attaches no terminal and changes nothing on screen. It tells the service when a prewarmed target sleeps
/// again (``IntentPrewarmService/cooled(_:)``). The service holds its warmer weakly, so the warmer may own the service.
public protocol IntentPrewarmWarming<Target>: AnyObject {
    associatedtype Target: Hashable & Sendable

    /// `target`'s content is hibernated or frozen, so a prewarm has work to do.
    func isCold(_ target: Target) -> Bool
    /// Starts the cheap kinds for `target`, on a background-class turn (never a press's input turn).
    func startPrewarm(_ target: Target, trigger: IntentPrewarmTrigger)
    /// Drops `target`'s prewarm, which the FIFO evicted or memory pressure cancelled before it was used.
    func cancelPrewarm(_ target: Target)
}

/// Intent prewarm for the sidebar's rows and the tab strip's tabs.
///
/// Pointer down: a press on a target that commits only on its release (a workspace row
/// with `sidebar.multiView`, a row of a multi-selection) reaches ``pointerPressed(on:)`` with that target,
/// is admitted to the FIFO and counted on the press's turn when it is cold; its work starts on the service's
/// press deadline, a background-class ``MainDeadline`` at zero, so it waits behind the press, the release and
/// visible work, and the press-to-release time is its head start. This is Chrome's conservative eagerness,
/// which starts on pointerdown and posts the speculation start rather than run it in input dispatch
/// (third_party/blink/renderer/core/html/anchor_element_interaction_tracker.cc, `OnPointerEvent`). A sidebar
/// press that switches on the press passes nil; the strip's tabs and the palette's rows also commit on the
/// press, so their commit (``committed(_:)``) ends the dwell and there is no release to prewarm ahead of.
/// A prewarm kept after a release elsewhere stays until evicted, used, or its page sleeps again by the
/// hibernation's own grace (``cooled(_:)``).
///
/// Hover dwell: a hover delivery (``pointerHovered(_:)``, from the sidebar's and the tab
/// strip's hover change) that reaches a cold target arms the service's one ``MainDeadline``; after ``dwell``
/// the target's prewarm starts. A delivery on another target re-arms it, one on nothing, a press or a commit
/// cancels it, so the timer is pending only while the pointer rests on a cold target. Chrome's hover
/// heuristic is the same one-shot timer, restarted per anchor and stopped on pointerout
/// (anchor_element_interaction_tracker.cc).
///
/// Key steps: after a person's next/previous key lands, ``stepped(_:toward:)`` arms the
/// service's step deadline, a background-class ``MainDeadline``, so the following item's prewarm runs after
/// input and frames, never in the key's turn. A step the other way cancels the old direction's held key-step
/// prewarms. Chrome steps tabs with no prediction; this is the speculation rules' FIFO and gating applied to
/// a held or repeated key.
///
/// The held prewarms are an ``IntentPrewarmQueue`` (FIFO of 2, oldest cancelled), shared by every trigger.
///
/// Nothing starts in Low Power Mode on battery or at memory pressure warning or worse
/// (`PreloadingEligibility::kBatterySaverEnabled`, `kMemoryPressure`); critical pressure also cancels the
/// held prewarms, as `PrerenderHostRegistry::OnMemoryPressure` cancels every host
/// (`kMemoryPressureAfterTriggered`).
@MainActor
public final class IntentPrewarmService<Target: Hashable & Sendable> {
    /// How long the pointer rests on a target before its prewarm starts (Chrome's moderate eagerness).
    public let dwell: Duration
    /// The held prewarms.
    public private(set) var queue = IntentPrewarmQueue<Target>()
    /// The target under the pointer, from the last hover delivery; nil on nothing.
    public private(set) var restingTarget: Target?
    /// What the service did.
    public private(set) var counters = IntentPrewarmCounters()
    /// Energy Saver's power inputs, pushed by the composition root. Entering Low Power Mode on battery
    /// cancels the pending dwell and step; the held prewarms stay until evicted or used.
    public var power: IntentPrewarmPower {
        didSet { if power.savesBattery { cancelPending() } }
    }
    /// The direction of the last key step; nil before the first.
    public private(set) var stepDirection: IntentPrewarmDirection?

    private weak var warmer: (any IntentPrewarmWarming<Target>)?
    private let memoryPressure: MemoryPressureEvents
    /// Nil: no hover dwell (`intentPrewarmHover` off), hover deliveries do nothing.
    private let dwellTimer: MainDeadline?
    /// Nil: no key-step prewarm (`directionalPrewarm` off).
    private let stepTimer: MainDeadline?
    /// Nil: no press prewarm (`intentPrewarmPress` off), a press only stops the dwell.
    private let pressStart: MainDeadline?
    /// Press prewarms admitted on their press's turn whose work waits for ``pressStart``, oldest first; each is held.
    private var unstarted: [Target] = []
    private var pressureObservation: MainActorHandlerRegistration<MemoryPressureLevel>?

    /// - Parameters:
    ///   - warmer: Says which target is cold and runs its prewarm; held weakly (gone: nothing is cold).
    ///   - memoryPressure: The app's one memory pressure source.
    ///   - dwellTimer: The hover dwell's deadline: a background-class `MainDeadline` on the app's deadline
    ///     scheduler (a prewarm is work nobody sees yet, so it waits behind input and visible work). Nil: no
    ///     hover dwell.
    ///   - stepTimer: The key steps' deadline, background class too. Nil: no key-step prewarm.
    ///   - pressStart: The press prewarms' start, background class too, scheduled at zero from the press, so
    ///     no warmer work runs on the press's input turn. Nil: no press prewarm.
    ///   - dwell: The rest before a hover prewarm; the `intentPrewarmHover` feature's `dwell` param.
    ///   - power: The power inputs now.
    public init(warmer: any IntentPrewarmWarming<Target>, memoryPressure: MemoryPressureEvents, dwellTimer: MainDeadline?,
                stepTimer: MainDeadline? = nil, pressStart: MainDeadline? = nil, dwell: Duration = .milliseconds(200),
                power: IntentPrewarmPower = IntentPrewarmPower()) {
        self.warmer = warmer
        self.memoryPressure = memoryPressure
        self.dwellTimer = dwellTimer
        self.stepTimer = stepTimer
        self.pressStart = pressStart
        self.dwell = dwell
        self.power = power
        pressureObservation = memoryPressure.observe { [weak self] level in self?.memoryPressureDidChange(level) }
    }

    // The timers and the pressure registration end themselves when released, on any thread.
    nonisolated deinit {}

    /// The dwell's deadline is pending (the pointer rests on a cold target).
    public var isDwelling: Bool { dwellTimer?.isScheduled == true }

    /// A key step's prewarm is posted and has not run yet.
    public var isStepPending: Bool { stepTimer?.isScheduled == true }

    /// A hover delivery: the pointer is on `target`, or on nothing. Another target restarts the dwell (when
    /// it is cold and not held); the same target keeps it, so repeated deliveries on one row cost a compare.
    public func pointerHovered(_ target: Target?) { // perf-hot: 5us intent-prewarm-hover (each hover target change)
        guard let dwellTimer, target != restingTarget else { return }
        restingTarget = target
        dwellTimer.cancel()
        guard let target, !queue.contains(target), let warmer, warmer.isCold(target), admits() else { return }
        dwellTimer.schedule(after: dwell) { [weak self] in self?.dwellElapsed() }
    }

    /// A press: the dwell stops and does not restart until the pointer reaches another target.
    /// `target` is what the press commits on its release, nil when it commits on the press or on nothing.
    /// With press prewarm on, a cold `target` not held yet is admitted and counted now (the FIFO, power and
    /// pressure rules hold) and its warmer work starts on the press deadline, never on this turn.
    public func pointerPressed(on target: Target? = nil) {
        dwellTimer?.cancel()
        guard let target, let pressStart, warmer?.isCold(target) == true,
              admit(target, trigger: .pointerDown) else { return }
        unstarted.append(target)
        pressStart.scheduleIfIdle(after: .zero) { [weak self] in self?.startPressed() }
    }

    /// A person's next/previous key went `direction`; `following` gives the targets one more step that way
    /// (the pages the next item shows), read when the step's prewarm runs. Call it in the key's turn: it only
    /// arms the background-class step deadline, replacing a step not run yet, so a held key's repeats cost one
    /// prewarm per run. A step the other way first cancels what the old direction holds.
    // perf-hot: 5us tab-switch (each next/previous key step)
    public func stepped(_ direction: IntentPrewarmDirection, toward following: @escaping @MainActor () -> [Target]) {
        guard let stepTimer else { return }
        if let previous = stepDirection, previous != direction { cancelSteps() }
        stepDirection = direction
        stepTimer.cancel()
        guard admits() else { return }
        stepTimer.schedule(after: .zero) { [weak self] in self?.stepElapsed(following()) }
    }

    /// Starts `target`'s prewarm unless it is held already, evicting the oldest past the queue's limit.
    /// Nothing starts in Low Power Mode on battery or at memory pressure warning or worse.
    public func prewarm(_ target: Target, trigger: IntentPrewarmTrigger) {
        guard admit(target, trigger: trigger) else { return }
        warmer?.startPrewarm(target, trigger: trigger)
    }

    /// `target` committed: its prewarm, if held and started, was used and leaves the FIFO without a cancel.
    /// One whose work had not started yet is no hit.
    public func committed(_ target: Target) {
        if restingTarget == target { dwellTimer?.cancel() }
        let started = !dropUnstarted(target)
        guard let trigger = queue.remove(target), started else { return }
        counters.used += 1
        counters.hits[trigger, default: 0] += 1
    }

    /// `target`'s page slept again (frozen or hibernated by the hibernation's grace): its prewarm is spent and
    /// leaves the FIFO with no use and no cancel, so a later press on that row prewarms it again.
    public func cooled(_ target: Target) {
        dropUnstarted(target)
        queue.remove(target)
    }

    /// Starts the counters over (`debug.input` action `reset`); the held prewarms stay.
    public func resetCounters() {
        counters = IntentPrewarmCounters()
    }

    /// `target`'s content went (its tab closed): it leaves the FIFO without a cancel or a use.
    public func forget(_ target: Target) {
        if restingTarget == target {
            restingTarget = nil
            dwellTimer?.cancel()
        }
        dropUnstarted(target)
        queue.remove(target)
    }

    /// The press deadline: the work of every press prewarm still held starts, oldest first.
    private func startPressed() {
        let targets = unstarted
        unstarted.removeAll()
        for target in targets { warmer?.startPrewarm(target, trigger: .pointerDown) }
    }

    /// Admits `target` unless it is held already or the power and pressure rules refuse, evicting the oldest
    /// past the queue's limit (an evicted prewarm that had not started needs no cancel), and counts the start.
    private func admit(_ target: Target, trigger: IntentPrewarmTrigger) -> Bool {
        guard !queue.contains(target), warmer != nil, admits() else { return false }
        if let evicted = queue.admit(target, trigger: trigger) {
            if !dropUnstarted(evicted) { warmer?.cancelPrewarm(evicted) }
            counters.evicted += 1
        }
        counters.started[trigger, default: 0] += 1
        return true
    }

    /// Takes `target` off the press prewarms waiting to start; true when it was waiting (its work never ran).
    @discardableResult
    private func dropUnstarted(_ target: Target) -> Bool {
        guard let index = unstarted.firstIndex(of: target) else { return false }
        unstarted.remove(at: index)
        if unstarted.isEmpty { pressStart?.cancel() }
        return true
    }

    /// The dwell's deadline: every target change cancels it, so `restingTarget` is the target it was armed on.
    private func dwellElapsed() {
        guard let target = restingTarget, warmer?.isCold(target) == true else { return }
        prewarm(target, trigger: .hoverDwell)
    }

    /// The step deadline: the following targets that are cold start, oldest first through the FIFO.
    private func stepElapsed(_ following: [Target]) {
        for target in following where !queue.contains(target) && warmer?.isCold(target) == true {
            prewarm(target, trigger: .keyStep)
        }
    }

    /// A step the other way: the old direction's pending step and held key-step prewarms are cancelled. The
    /// queue keeps each held prewarm's trigger, so a hover's or a press's prewarm stays.
    private func cancelSteps() {
        stepTimer?.cancel()
        let dropped = queue.removeAll(startedBy: .keyStep)
        counters.cancelledByDirection += dropped.count
        for target in dropped { warmer?.cancelPrewarm(target) }
    }

    /// Drops the pending dwell and step (Low Power Mode on battery, memory pressure).
    private func cancelPending() {
        dwellTimer?.cancel()
        stepTimer?.cancel()
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
        cancelPending()
        guard level == .critical else { return }
        let dropped = queue.removeAll()
        counters.cancelledByPressure += dropped.count
        for target in dropped where !dropUnstarted(target) { warmer?.cancelPrewarm(target) }
    }
}
