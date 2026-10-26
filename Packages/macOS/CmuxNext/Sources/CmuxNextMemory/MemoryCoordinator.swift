public import CmuxNextCompat

/// The app's one memory coordinator: it sets each registered ``MemoryConsumer``'s limit from the
/// memory pressure level and the Memory Saver mode, and releases what is above the limits in short
/// slices on later frames, cheapest memory first.
///
/// A port of Chrome's `base/memory_coordinator/` (the registry and `memory_consumer.h`'s two calls)
/// with the limits of `memory_saver_memory_coordinator_policy.cc`, as ``MemoryLimitPolicy`` states.
/// cmux differs from Chrome in how it releases: Chrome calls `OnReleaseMemory()` on every consumer
/// in the pressure event's turn; cmux keeps the main thread inside its frame budget, so:
///
/// - A level change sets the new limits at once (``MemoryConsumer/updateMemoryLimit(_:)``, which
///   frees nothing) and asks the injected ``MemoryReleaseSlicer`` for one slice on the next frame,
///   never in the event's turn.
/// - Each slice gives the consumers whose limit fell, in ``MemoryReleaseOrder``, one shared budget
///   (2 ms on the injected clock). A consumer stops when the slice expires; the next one waits for a
///   later frame. A consumer that frees one item per frame (``MemoryReleaseProgress/yield``) leaves
///   the rest of the slice to the ones after it and goes again on the next frame, so a pass ordered
///   later (the urgent page discard) never waits for it to finish.
/// - A consumer whose limit rises again before its release ran is not called: critical then normal
///   in one frame makes no release call.
/// - A repeated level makes no call at all.
/// - A consumer that registers gets the current limit before its registration's init returns, and
///   joins the release when that limit is under 100 %.
/// - A ``MemoryLevelConsumer`` (a lossy planner with its own pace) also gets the level: at
///   registration and after the limits of each level change.
/// - A slice only unlinks: consumers put what they free in ``releaseSink``, which drops it on a
///   utility-QoS queue. Each escalation to critical asks the sink for one heap relief when that
///   level's release pass has finished; warning, a repeated level, or a level that leaves critical
///   before the pass ends asks for none.
/// - While no cmux window is visible (``isAppHidden``) there is no frame to protect, and the hidden
///   app's frames come only on the frame scheduler's stall deadline (2 ms per 100 ms). Slices then
///   take 8 ms each, back to back on main-queue turns from the injected ``MemoryReleaseTurns``.
///   Input (``inputDidArrive()``) or a window that shows puts the next slice back on a frame, at 2 ms.
///
/// The level is the debug override when set (`debug.hibernation.pressure`), else the kernel's level
/// from ``MemoryPressureEvents`` (read at init, then each change). Nothing here waits or reads on a
/// schedule: the pressure events, the app's visibility and input calls, and the slicer's frames and
/// turns are its only inputs. The level is also its
/// vote in in-process Chromium's pressure aggregator (``pressureVote``, p07-memory-051), next to
/// Chromium's own platform voter.
///
/// ```swift
/// let coordinator = MemoryCoordinator(
///     pressure: memoryPressure, mode: .medium, slicer: frameSlicer, turns: mainTurns,
///     releaseSink: MemoryReleaseSink())
/// coordinator.isAppHidden = !windows.anyDraws || displaysAsleep
/// let cache = PreviewImageCache(sink: coordinator.releaseSink)
/// registration = MemoryConsumerRegistration(
///     name: "preview-images", traits: traits, consumer: cache, registry: coordinator)
/// ```
@MainActor
public final class MemoryCoordinator: MemoryConsumerRegistry, MemoryPressureVoteSource {
    /// The main-thread time one release slice may take (p07-memory.md section 3.A).
    public nonisolated static let sliceBudget: Duration = .milliseconds(2)
    /// The main-thread time one release slice may take while no cmux window is visible.
    public nonisolated static let hiddenSliceBudget: Duration = .milliseconds(8)

    /// How the release slices are paced.
    public nonisolated enum ReleasePace: Hashable, Sendable {
        /// One slice of at most ``MemoryCoordinator/sliceBudget`` per frame.
        case frames
        /// Slices of at most ``MemoryCoordinator/hiddenSliceBudget``, back to back on main-queue turns.
        case hiddenTurns
    }

    /// The level the limits come from: ``pressureOverride`` when set, else ``kernelLevel``.
    public private(set) var level: MemoryPressureLevel
    /// The kernel's level, as ``MemoryPressureEvents`` last reported it.
    public private(set) var kernelLevel: MemoryPressureLevel

    /// A level that replaces the kernel's until it is set back to nil (`debug.hibernation.pressure`).
    public var pressureOverride: MemoryPressureLevel? {
        didSet {
            guard pressureOverride != oldValue else { return }
            levelInputsDidChange()
        }
    }

    /// The level cmux votes into in-process Chromium's pressure aggregator (``MemoryPressureVoteSource``):
    /// ``level``, the override when set, else the cmux level. Normal is Chromium's none. Each change of
    /// ``level`` is told to the vote's observers after the new limits and the level consumers.
    public var pressureVote: MemoryPressureLevel { level }

    /// The `memory.saver` mode. Changing it changes only the limits of consumers that take a mode
    /// share at the current level.
    public var mode: MemorySaverMode {
        get { policy.mode }
        set {
            guard newValue != policy.mode else { return }
            policy.mode = newValue
            applyLimits()
        }
    }

    /// Whether no cmux window is visible: none draws (`WindowDrawPolicy`) or the displays sleep.
    /// The app sets it from its windows' occlusion and the display sleep and wake notifications.
    public var isAppHidden = false {
        didSet {
            guard isAppHidden != oldValue else { return }
            inputSinceHidden = false
            paceInputsDidChange()
        }
    }

    /// The pace of the next slice: ``ReleasePace/hiddenTurns`` while the app is hidden, no input came
    /// since it was hidden and a ``MemoryReleaseTurns`` was given; else ``ReleasePace/frames``.
    public var pace: ReleasePace {
        isAppHidden && !inputSinceHidden && turns != nil ? .hiddenTurns : .frames
    }

    /// The registered consumers in ``MemoryReleaseOrder`` (equal orders in registration order),
    /// each with its limit and release state. The list drops released registrations on each add
    /// and walk.
    let consumers: MemoryConsumerList<Record>

    /// Where consumers drop what a slice unlinked; the composition root hands it to each consumer.
    public let releaseSink: MemoryReleaseSink

    private var policy: MemoryLimitPolicy
    /// A consumer is over its limit, or a heap relief is due, and waits for a slice.
    private var needsSlice = false
    private var isFrameAsked = false
    private var isTurnAsked = false
    private var inputSinceHidden = false
    /// Set by an escalation to critical; the slice that finishes that pass relieves the heap once.
    private var isHeapReliefDue = false
    private let slicer: any MemoryReleaseSlicer
    private let turns: (any MemoryReleaseTurns)?
    private let clock: any Clock<Duration>
    private let sliceDuration: Duration
    private let hiddenSliceDuration: Duration
    private var pressureObservation: MainActorHandlerRegistration<MemoryPressureLevel>?
    private let voteHandlers = MainActorHandlers<MemoryPressureLevel>()

    /// Makes the coordinator and starts following `pressure`, from its current level.
    ///
    /// - Parameters:
    ///   - pressure: The process's one pressure source.
    ///   - mode: The `memory.saver` mode.
    ///   - slicer: Runs release slices on later frames.
    ///   - turns: Runs release slices on later main-queue turns while the app is hidden; without it
    ///     every slice waits for a frame.
    ///   - clock: Measures each slice's budget (`ContinuousClock` in the app, a fake in tests).
    ///   - sliceBudget: The time one slice on a frame may take.
    ///   - hiddenSliceBudget: The time one slice on a turn of a hidden app may take.
    ///   - releaseSink: Drops what consumers unlinked and relieves the heap, off the main thread.
    public init(
        pressure: MemoryPressureEvents,
        mode: MemorySaverMode = .medium,
        slicer: any MemoryReleaseSlicer,
        turns: (any MemoryReleaseTurns)? = nil,
        clock: any Clock<Duration> = ContinuousClock(),
        sliceBudget: Duration = MemoryCoordinator.sliceBudget,
        hiddenSliceBudget: Duration = MemoryCoordinator.hiddenSliceBudget,
        releaseSink: MemoryReleaseSink = MemoryReleaseSink()
    ) {
        let initial = pressure.currentLevel
        level = initial
        kernelLevel = initial
        policy = MemoryLimitPolicy(mode: mode)
        self.slicer = slicer
        self.turns = turns
        self.clock = clock
        sliceDuration = sliceBudget
        hiddenSliceDuration = hiddenSliceBudget
        consumers = MemoryConsumerList(orderedBy: { $0.order < $1.order })
        self.releaseSink = releaseSink
        pressureObservation = pressure.observe { [weak self] level in self?.kernelLevelDidChange(level) }
    }

    /// The limit a consumer with `traits` has at the current level and mode.
    ///
    /// - Parameter traits: The consumer's traits.
    /// - Returns: Its limit.
    public func limit(for traits: MemoryConsumerTraits) -> MemoryLimit {
        policy.limit(for: traits, at: level)
    }

    /// What every live consumer holds now, with the limit it has and the level and mode the limits
    /// come from (Chrome's memory-infra dump, `base/trace_event/memory_dump_manager.h`).
    ///
    /// One pass over the consumers, O(consumers), on the main actor, in release order: one
    /// ``MemoryConsumer/memoryUsage`` read per live consumer and no lock held across consumers. A
    /// consumer on another actor registers through the asynchronous registration (Chrome's
    /// `base/memory_coordinator/async_memory_consumer_registration.h`), whose main-actor
    /// `memoryUsage` is the last value it sent, so the report never waits for an actor. Released
    /// registrations are left out; a consumer that cannot tell its size shows as unknown, never 0.
    ///
    /// - Parameter budget: The app's budgets at normal pressure (the app's `DebugMemoryControl.budget`).
    /// - Returns: The snapshot `debug.memory` serves.
    public func report(budget: SubsystemBudget) -> MemoryReport {
        let records = consumers.liveRecords()
        var rows: [MemoryReport.Consumer] = []
        rows.reserveCapacity(records.count)
        for record in records {
            guard let consumer = record.entry.liveConsumer else { continue }
            rows.append(
                MemoryReport.Consumer(
                    name: record.entry.name, traits: record.entry.traits, limit: record.limit,
                    usage: consumer.memoryUsage)
            )
        }
        return MemoryReport(level: level, mode: mode, budget: budget, consumers: rows)
    }

    /// Notes that the person gave input: while the app is hidden, the next slice goes back to a frame
    /// at ``sliceBudget`` until the app is hidden again. Cheap enough for every input event.
    public func inputDidArrive() {
        guard isAppHidden, !inputSinceHidden else { return }
        inputSinceHidden = true
        paceInputsDidChange()
    }

    public func observePressureVote(_ handler: @escaping @MainActor @Sendable (MemoryPressureLevel) -> Void)
        -> MainActorHandlerRegistration<MemoryPressureLevel> {
        voteHandlers.add(handler)
    }

    public func addMemoryConsumer(_ entry: MemoryConsumerEntry) {
        let current = self.limit(for: entry.traits)
        let record = Record(entry: entry, limit: current)
        consumers.add(record)
        entry.liveConsumer?.updateMemoryLimit(current)
        (entry.liveConsumer as? any MemoryLevelConsumer)?.memoryLevelDidChange(level)
        if record.needsRelease { scheduleSlice() }
    }

    private func kernelLevelDidChange(_ newLevel: MemoryPressureLevel) {
        kernelLevel = newLevel
        levelInputsDidChange()
    }

    private func levelInputsDidChange() {
        let newLevel = pressureOverride ?? kernelLevel
        guard newLevel != level else { return }
        level = newLevel
        isHeapReliefDue = newLevel == .critical
        applyLimits()
        for entry in consumers.liveEntries() {
            (entry.liveConsumer as? any MemoryLevelConsumer)?.memoryLevelDidChange(newLevel)
        }
        voteHandlers.call(newLevel)
        // The relief follows the pass, so a critical level with nothing to release still gets one.
        if isHeapReliefDue { scheduleSlice() }
    }

    /// Hands each consumer whose limit changed its new limit, and asks for a slice when one fell.
    private func applyLimits() {
        var needsRelease = false
        for record in consumers.liveRecords() {
            let newLimit = self.limit(for: record.entry.traits)
            guard newLimit != record.limit, let consumer = record.entry.liveConsumer else { continue }
            record.setLimit(newLimit)
            needsRelease = needsRelease || record.needsRelease
            consumer.updateMemoryLimit(newLimit)
        }
        if needsRelease { scheduleSlice() }
    }

    private func scheduleSlice() {
        needsSlice = true
        askForSlice()
    }

    /// Asks the current pace's scheduler for a slice, unless one is asked for there already.
    private func askForSlice() {
        switch pace {
        case .frames:
            guard !isFrameAsked else { return }
            isFrameAsked = true
            slicer.scheduleSlice { [weak self] in self?.sliceDidCome(on: .frames) }
        case .hiddenTurns:
            guard !isTurnAsked, let turns else { return }
            isTurnAsked = true
            turns.scheduleTurn { [weak self] in self?.sliceDidCome(on: .hiddenTurns) }
        }
    }

    /// A waiting slice moves to the new pace's scheduler; the one asked for on the old pace finds
    /// the pace changed when it comes and does nothing.
    private func paceInputsDidChange() {
        if needsSlice { askForSlice() }
    }

    private func sliceDidCome(on arrived: ReleasePace) {
        switch arrived {
        case .frames: isFrameAsked = false
        case .hiddenTurns: isTurnAsked = false
        }
        guard arrived == pace, needsSlice else { return }
        runSlice(for: arrived == .frames ? sliceDuration : hiddenSliceDuration)
    }

    /// One slice's release: the consumers over their limit, in order, until `duration` is spent.
    private func runSlice(for duration: Duration) {
        needsSlice = false
        let isExpired = Self.deadline(on: clock, after: duration)
        for record in consumers.liveRecords() where record.needsRelease {
            guard !isExpired() else {
                scheduleSlice()
                return
            }
            // A consumer called before may have released this one's registration.
            guard let consumer = record.entry.liveConsumer else { continue }
            let target = record.limit
            switch consumer.releaseMemory(within: MemoryReleaseSlice(limit: target, isExpired: isExpired)) {
            case .done:
                record.didRelease(to: target)
            case .more:
                scheduleSlice()
                return
            case .yield:
                scheduleSlice()
            }
        }
        // A consumer that registered during this slice may have asked for another; it ends the pass.
        if isHeapReliefDue, !needsSlice {
            isHeapReliefDue = false
            releaseSink.relieveHeap()
        }
    }

    /// A check that turns true `duration` after now on `clock`, shared by every consumer of one slice.
    private nonisolated static func deadline(on clock: some Clock<Duration>, after duration: Duration)
        -> @Sendable () -> Bool {
        let end = clock.now.advanced(by: duration)
        return { clock.now >= end }
    }
}

extension MemoryCoordinator {
    /// One registered consumer and what the coordinator knows of it.
    final class Record: MemoryConsumerListRecord {
        let entry: MemoryConsumerEntry
        let order: MemoryReleaseOrder
        /// The limit it was last given.
        private(set) var limit: MemoryLimit
        /// The most it may hold now: its limit when it last finished a release, or a higher limit given
        /// since. It needs a release while its limit is below this.
        private var heldBound = MemoryLimit.default

        init(entry: MemoryConsumerEntry, limit: MemoryLimit) {
            self.entry = entry
            order = MemoryReleaseOrder(traits: entry.traits)
            self.limit = limit
        }

        var needsRelease: Bool {
            limit < heldBound
        }

        func setLimit(_ newLimit: MemoryLimit) {
            limit = newLimit
            heldBound = max(heldBound, newLimit)
        }

        /// Records a finished release down to `released`; a limit given during the call still counts.
        func didRelease(to released: MemoryLimit) {
            heldBound = max(released, limit)
        }
    }
}
