public import CmuxNextCompat
public import CmuxNextWakeups

/// The owner of the targets' content (the hibernation and page hosts): says which target is cold and
/// runs the cheap prewarm kinds (hibernated page cover decode, hidden renderer start, target geometry).
/// A prewarm writes nothing to the daemon, attaches no terminal and changes nothing on screen.
public protocol IntentPrewarmWarming<Target>: AnyObject {
    associatedtype Target: Hashable & Sendable

    /// `target`'s content is hibernated or not loaded, so a prewarm has work to do.
    func isCold(_ target: Target) -> Bool
    /// Starts the cheap kinds for `target`.
    func startPrewarm(_ target: Target, trigger: IntentPrewarmTrigger)
    /// Drops `target`'s prewarm, which the FIFO evicted or memory pressure cancelled before it was used.
    func cancelPrewarm(_ target: Target)
}

/// Intent prewarm for targets that commit on release (tab cells, multi-view sidebar rows, palette rows).
///
/// Hover dwell (p04-input-043): a hover delivery (``pointerHovered(_:)``, once per frame from the sidebar's
/// and the tab strip's ``PointerFrameHover``) that reaches a cold target arms the service's one
/// ``DemandTimer``; after ``dwell`` the target's prewarm starts. A delivery on another target re-arms it,
/// one on nothing, a press or a commit cancels it, so the timer is pending only while the pointer rests on
/// a cold target. Chrome's hover heuristic is the same one-shot timer, restarted per anchor and stopped on
/// pointerout (anchor_element_interaction_tracker.cc).
///
/// At most ``fifoLimit`` prewarms are held, oldest evicted first, as Chrome holds at most two non-eager
/// prerenders (content/browser/preloading/prerender/prerender_host_registry.cc,
/// `kMaxNumOfRunningNonEagerPrerendersExceeded`).
///
/// Nothing starts in Low Power Mode on battery or at memory pressure warning or worse
/// (`PreloadingEligibility::kBatterySaverEnabled`, `kMemoryPressure`); critical pressure also cancels the
/// held prewarms, as `PrerenderHostRegistry::OnMemoryPressure` cancels every host
/// (`kMemoryPressureAfterTriggered`).
@MainActor
public final class IntentPrewarmService<Target: Hashable & Sendable> {
    /// How many prewarms are held at once.
    public let fifoLimit = 2
    /// How long the pointer rests on a target before its prewarm starts (Chrome's moderate eagerness).
    public let dwell: Duration
    /// The held prewarms, oldest first.
    public private(set) var prewarmed: [Target] = []
    /// The target under the pointer, from the last hover delivery; nil on nothing.
    public private(set) var restingTarget: Target?
    /// What the service did.
    public private(set) var counters = IntentPrewarmCounters()
    /// Energy Saver's power inputs, pushed by the composition root. Entering Low Power Mode on battery
    /// cancels the dwell; the held prewarms stay until evicted or used.
    public var power: IntentPrewarmPower {
        didSet { if power.savesBattery { dwellTimer.cancel() } }
    }

    private let warmer: any IntentPrewarmWarming<Target>
    private let memoryPressure: MemoryPressureEvents
    private let dwellTimer: DemandTimer
    private var pressureObservation: MainActorHandlerRegistration<MemoryPressureLevel>?

    /// - Parameters:
    ///   - warmer: Says which target is cold and runs its prewarm.
    ///   - memoryPressure: The app's one memory pressure source.
    ///   - dwellTimer: The service's one deadline, `DemandTimer(owner: "IntentPrewarm.hoverDwell", mainWork:)`
    ///     in the app; tests pass one on a `ManualClock`.
    ///   - dwell: The rest before a hover prewarm; the `intentPrewarmHover` feature's `dwell` param.
    ///   - power: The power inputs now.
    public init(warmer: any IntentPrewarmWarming<Target>, memoryPressure: MemoryPressureEvents, dwellTimer: DemandTimer,
                dwell: Duration = .milliseconds(200), power: IntentPrewarmPower = IntentPrewarmPower()) {
        self.warmer = warmer
        self.memoryPressure = memoryPressure
        self.dwellTimer = dwellTimer
        self.dwell = dwell
        self.power = power
        pressureObservation = memoryPressure.observe { [weak self] level in self?.memoryPressureDidChange(level) }
    }

    // The timer and the pressure registration end themselves when released, on any thread.
    nonisolated deinit {}

    /// The dwell's deadline is pending (the pointer rests on a cold target).
    public var isDwelling: Bool { dwellTimer.isScheduled }

    /// A hover delivery: the pointer is on `target`, or on nothing. Another target restarts the dwell (when
    /// it is cold and not held); the same target keeps it, so per-frame deliveries on one row cost a compare.
    public func pointerHovered(_ target: Target?) {
        guard target != restingTarget else { return }
        restingTarget = target
        dwellTimer.cancel()
        guard let target, !prewarmed.contains(target), warmer.isCold(target), admits() else { return }
        dwellTimer.scheduleOnMain(after: dwell) { [weak self] in self?.dwellElapsed() }
    }

    /// A press: the dwell stops and does not restart until the pointer reaches another target (the press's
    /// own prewarm, if any, goes through ``prewarm(_:trigger:)``).
    public func pointerPressed() {
        dwellTimer.cancel()
    }

    /// Starts `target`'s prewarm unless it is held already, evicting the oldest past ``fifoLimit``.
    /// Nothing starts in Low Power Mode on battery or at memory pressure warning or worse.
    public func prewarm(_ target: Target, trigger: IntentPrewarmTrigger) {
        guard !prewarmed.contains(target), admits() else { return }
        if prewarmed.count == fifoLimit {
            warmer.cancelPrewarm(prewarmed.removeFirst())
            counters.evicted += 1
        }
        prewarmed.append(target)
        counters.started[trigger, default: 0] += 1
        warmer.startPrewarm(target, trigger: trigger)
    }

    /// `target` committed: its prewarm, if held, was used and leaves the FIFO without a cancel.
    public func committed(_ target: Target) {
        if restingTarget == target { dwellTimer.cancel() }
        guard let index = prewarmed.firstIndex(of: target) else { return }
        prewarmed.remove(at: index)
        counters.used += 1
    }

    /// The dwell's deadline: every target change cancels it, so `restingTarget` is the target it was armed on.
    private func dwellElapsed() {
        guard let target = restingTarget, warmer.isCold(target) else { return }
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
        let dropped = prewarmed
        prewarmed.removeAll()
        counters.cancelledByPressure += dropped.count
        for target in dropped { warmer.cancelPrewarm(target) }
    }
}
