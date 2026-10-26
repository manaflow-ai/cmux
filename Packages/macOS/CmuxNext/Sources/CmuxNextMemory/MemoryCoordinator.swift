public import CmuxNextCompat
public import CmuxNextWakeups

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
/// - Hysteresis (p07-memory-070): after the level falls, lossless consumers keep the limits of the
///   stricter ``limitLevel`` until the level has not changed for ``limitRiseDelay`` (30 s, one
///   ``MainDeadline`` one-shot that each change resets); a rise back cancels the wait. Only limits a
///   release already ran at are held, so a level that comes back before its release still releases
///   nothing. Warning/normal flaps then make one release pass and no refill between them. Lossy
///   consumers (page discards, snapshots) follow ``level`` at once, so their release stops when the
///   pressure does. Chromium damps repeated moderate signals with a cooldown
///   (`kModeratePressureCooldown`, components/memory_pressure/system_memory_pressure_evaluator_win.cc);
///   cmux damps the limits instead, since macOS WARN flaps (p07-memory.md section 3.A).
/// - Working set: a limit applies only to a consumer's entries not used in the last 2 s
///   (``MemoryLimit/workingSet``); the consumer reports its in-use entries to
///   ``MemoryLimit/scale(_:inUse:)``. A release that kept some says when the first ages out
///   (``MemoryReleaseProgress/keptWorkingSet(agesOutIn:)``), and one ``MainDeadline`` one-shot then
///   asks those consumers for one more release at the same limit.
///
/// The level is the debug override when set (`debug.hibernation.pressure`), else the kernel's level
/// from ``MemoryPressureEvents`` (read at init, then each change). Nothing here waits or reads on a
/// schedule: the pressure events, the slicer's frames and the hysteresis and working-set one-shots
/// are its only inputs. The level is also its vote in in-process Chromium's pressure aggregator
/// (``pressureVote``, p07-memory-051), next to Chromium's own platform voter.
///
/// ```swift
/// let coordinator = MemoryCoordinator(pressure: memoryPressure, mode: .medium, slicer: frameSlicer)
/// registration = MemoryConsumerRegistration(
///     name: "preview-images", traits: traits, consumer: cache, registry: coordinator)
/// ```
@MainActor
public final class MemoryCoordinator: MemoryConsumerRegistry, MemoryPressureVoteSource {
    /// The main-thread time one release slice may take (p07-memory.md section 3.A).
    public nonisolated static let sliceBudget: Duration = .milliseconds(2)
    /// How long the level must stay below ``limitLevel`` before lossless limits rise
    /// (p07-memory.md section 3.A).
    public nonisolated static let limitRiseDelay: Duration = .seconds(30)

    /// The level: ``pressureOverride`` when set, else ``kernelLevel``. Lossy limits, level consumers
    /// and the vote follow it at once; lossless limits follow ``limitLevel``.
    public private(set) var level: MemoryPressureLevel
    /// The kernel's level, as ``MemoryPressureEvents`` last reported it.
    public private(set) var kernelLevel: MemoryPressureLevel
    /// The level lossless consumers' limits come from: ``level``, or the stricter level it fell from,
    /// held until the level has not changed for ``limitRiseDelay``.
    public private(set) var limitLevel: MemoryPressureLevel

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

    /// The registered consumers in ``MemoryReleaseOrder`` (equal orders in registration order),
    /// each with its limit and release state. The list drops released registrations on each add
    /// and walk.
    let consumers: MemoryConsumerList<Record>
    private var policy: MemoryLimitPolicy
    private var isSliceScheduled = false
    private let slicer: any MemoryReleaseSlicer
    private let clock: any Clock<Duration>
    private let sliceDuration: Duration
    private var pressureObservation: MainActorHandlerRegistration<MemoryPressureLevel>?
    /// Ends a hold of ``limitLevel``; nil raises limits with the level.
    private let limitRiseDeadline: MainDeadline?
    /// The strictest level whose lossless limits a release ran at since those limits last rose. A fall
    /// holds ``limitLevel`` here at most: a stricter level whose release never ran is not held.
    private var releasedLimitLevel: MemoryPressureLevel = .normal
    /// Asks consumers that kept working-set entries for one more release once the first ages out; nil
    /// never asks again.
    private let workingSetDeadline: MainDeadline?
    /// When the armed working-set one-shot fires, on ``elapsed``.
    private var workingSetDue: Duration?
    /// The time since init on the coordinator's clock.
    private let elapsed: @Sendable () -> Duration
    private let voteHandlers = MainActorHandlers<MemoryPressureLevel>()

    /// Makes the coordinator and starts following `pressure`, from its current level.
    ///
    /// - Parameters:
    ///   - pressure: The process's one pressure source.
    ///   - mode: The `memory.saver` mode.
    ///   - slicer: Runs release slices on later frames.
    ///   - clock: Measures each slice's budget (`ContinuousClock` in the app, a fake in tests).
    ///   - sliceBudget: The time one slice may take.
    ///   - limitRiseDeadline: The one-shot that ends a hold of ``limitLevel`` after ``limitRiseDelay`` (the
    ///     app's is a background-class deadline on its one placer). Nil raises limits with the level: no
    ///     hysteresis.
    ///   - workingSetDeadline: The one-shot that asks consumers that kept working-set entries for one more
    ///     release once the first ages out (the app's is a background-class deadline on its one placer). Nil
    ///     never asks again.
    public init(
        pressure: MemoryPressureEvents,
        mode: MemorySaverMode = .medium,
        slicer: any MemoryReleaseSlicer,
        clock: any Clock<Duration> = ContinuousClock(),
        sliceBudget: Duration = MemoryCoordinator.sliceBudget,
        limitRiseDeadline: MainDeadline? = nil,
        workingSetDeadline: MainDeadline? = nil
    ) {
        let initial = pressure.currentLevel
        level = initial
        kernelLevel = initial
        limitLevel = initial
        self.limitRiseDeadline = limitRiseDeadline
        self.workingSetDeadline = workingSetDeadline
        elapsed = Self.stopwatch(on: clock)
        policy = MemoryLimitPolicy(mode: mode)
        self.slicer = slicer
        self.clock = clock
        sliceDuration = sliceBudget
        consumers = MemoryConsumerList(orderedBy: { $0.order < $1.order })
        pressureObservation = pressure.observe { [weak self] level in self?.kernelLevelDidChange(level) }
    }

    /// The limit a consumer with `traits` has at the current level and mode: at ``limitLevel`` when it
    /// is lossless, at ``level`` when it is lossy.
    ///
    /// - Parameter traits: The consumer's traits.
    /// - Returns: Its limit.
    public func limit(for traits: MemoryConsumerTraits) -> MemoryLimit {
        policy.limit(for: traits, at: traits.retention == .lossless ? limitLevel : level)
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
        // releasedLimitLevel is never stricter than limitLevel, so a rise always takes the else branch.
        let held = newLevel.stricter(releasedLimitLevel)
        if let limitRiseDeadline, held != newLevel {
            setLimitLevel(held)
            limitRiseDeadline.schedule(after: Self.limitRiseDelay) { [weak self] in self?.limitHoldDidEnd() }
        } else {
            limitRiseDeadline?.cancel()
            setLimitLevel(newLevel)
        }
        applyLimits()
        for entry in consumers.liveEntries() {
            (entry.liveConsumer as? any MemoryLevelConsumer)?.memoryLevelDidChange(newLevel)
        }
        voteHandlers.call(newLevel)
    }

    /// The level stayed under the held ``limitLevel`` for ``limitRiseDelay``: lossless limits rise.
    private func limitHoldDidEnd() {
        guard limitLevel != level else { return }
        setLimitLevel(level)
        applyLimits()
    }

    private func setLimitLevel(_ newLevel: MemoryPressureLevel) {
        limitLevel = newLevel
        if releasedLimitLevel.severity > newLevel.severity { releasedLimitLevel = newLevel }
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
        guard !isSliceScheduled else { return }
        isSliceScheduled = true
        slicer.scheduleSlice { [weak self] in self?.runSlice() }
    }

    /// One frame's release: the consumers over their limit, in order, until the slice's time is spent.
    private func runSlice() {
        isSliceScheduled = false
        let isExpired = Self.deadline(on: clock, after: sliceDuration)
        for record in consumers.liveRecords() where record.needsRelease {
            guard !isExpired() else {
                scheduleSlice()
                return
            }
            // A consumer called before may have released this one's registration.
            guard let consumer = record.entry.liveConsumer else { continue }
            let target = record.limit
            if record.entry.traits.retention == .lossless {
                releasedLimitLevel = releasedLimitLevel.stricter(limitLevel)
            }
            switch consumer.releaseMemory(within: MemoryReleaseSlice(limit: target, isExpired: isExpired)) {
            case .done:
                record.didRelease(to: target, keptWorkingSet: false)
            case .keptWorkingSet(let agesOutIn):
                record.didRelease(to: target, keptWorkingSet: true)
                scheduleWorkingSetRelease(after: agesOutIn)
            case .more:
                scheduleSlice()
                return
            case .yield:
                scheduleSlice()
            }
        }
    }

    /// Arms the working-set one-shot `delay` from now, unless it is already armed to fire sooner.
    private func scheduleWorkingSetRelease(after delay: Duration) {
        guard let workingSetDeadline else { return }
        let delay = max(delay, .zero)
        let due = elapsed() + delay
        if let workingSetDue, workingSetDue <= due, workingSetDeadline.isScheduled { return }
        workingSetDue = due
        workingSetDeadline.schedule(after: delay) { [weak self] in self?.workingSetDidAgeOut() }
    }

    /// Entries a release kept for the working set may have aged out: each consumer that kept some and is
    /// still under its full limit gets one more release at that limit.
    private func workingSetDidAgeOut() {
        workingSetDue = nil
        var needsRelease = false
        for record in consumers.liveRecords() {
            record.workingSetDidAgeOut()
            needsRelease = needsRelease || record.needsRelease
        }
        if needsRelease { scheduleSlice() }
    }

    /// A reading of the time since now on `clock`.
    private nonisolated static func stopwatch(on clock: some Clock<Duration>) -> @Sendable () -> Duration {
        let start = clock.now
        return { start.duration(to: clock.now) }
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
        /// Whether its last finished release kept entries only because they were in the working set.
        private var keptWorkingSet = false
        /// Whether those entries may have aged out since: it needs one more release at its limit.
        private var isWorkingSetDue = false

        init(entry: MemoryConsumerEntry, limit: MemoryLimit) {
            self.entry = entry
            order = MemoryReleaseOrder(traits: entry.traits)
            self.limit = limit
        }

        var needsRelease: Bool {
            limit < heldBound || (isWorkingSetDue && limit < .default)
        }

        func setLimit(_ newLimit: MemoryLimit) {
            limit = newLimit
            heldBound = max(heldBound, newLimit)
            if newLimit == .default {
                keptWorkingSet = false
                isWorkingSetDue = false
            }
        }

        /// Records a finished release down to `released`; a limit given during the call still counts.
        ///
        /// - Parameters:
        ///   - released: The limit it released down to.
        ///   - kept: Whether it kept working-set entries above that limit.
        func didRelease(to released: MemoryLimit, keptWorkingSet kept: Bool) {
            heldBound = max(released, limit)
            keptWorkingSet = kept
            isWorkingSetDue = false
        }

        /// The working-set one-shot fired: a record that kept working-set entries needs one more release.
        func workingSetDidAgeOut() {
            isWorkingSetDue = keptWorkingSet
        }
    }
}

extension MemoryPressureLevel {
    /// How strict the level is: ``MemoryCoordinator`` holds lossless limits through a fall in it.
    fileprivate var severity: Int {
        switch self {
        case .normal: 0
        case .warning: 1
        case .critical: 2
        }
    }

    /// The stricter of this level and `other`.
    fileprivate func stricter(_ other: MemoryPressureLevel) -> MemoryPressureLevel {
        other.severity > severity ? other : self
    }
}
