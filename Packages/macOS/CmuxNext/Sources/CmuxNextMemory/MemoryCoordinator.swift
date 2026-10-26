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
///   later frame.
/// - A consumer whose limit rises again before its release ran is not called: critical then normal
///   in one frame makes no release call.
/// - A repeated level makes no call at all.
/// - While no cmux window is visible (``isAppHidden``) there is no frame to protect and the hidden
///   app's frames come only on the stall deadline, so slices take 8 ms each, back to back on
///   main-queue turns from the injected ``MemoryReleaseTurns``. Input (``inputDidArrive()``) or a
///   window that shows puts the next slice back on a frame, at 2 ms.
/// - A consumer that registers gets the current limit before its registration's init returns, and
///   joins the release when that limit is under 100 %.
///
/// The level is the debug override when set (`debug.hibernation.pressure`), else the kernel's level
/// from ``MemoryPressureEvents`` (read at init, then each change). Nothing here waits or polls: the
/// pressure events, the app's visibility and input calls, and the slicer's frames and turns are its
/// only inputs.
///
/// ```swift
/// let coordinator = MemoryCoordinator(
///     pressure: memoryPressure, mode: .medium, slicer: frameSlicer, turns: mainTurns)
/// coordinator.isAppHidden = !windows.anyDraws || displaysAsleep
/// registration = MemoryConsumerRegistration(
///     name: "preview-images", traits: traits, consumer: cache, registry: coordinator)
/// ```
@MainActor
public final class MemoryCoordinator: MemoryConsumerRegistry {
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

    private var policy: MemoryLimitPolicy
    /// The registered consumers in release order; released entries are dropped on each add and walk.
    private var consumers: [Registered] = []
    private var nextSequence: UInt64 = 0
    /// A consumer is over its limit and waits for a slice.
    private var needsSlice = false
    private var isFrameAsked = false
    private var isTurnAsked = false
    private var inputSinceHidden = false
    private let slicer: any MemoryReleaseSlicer
    private let turns: (any MemoryReleaseTurns)?
    private let clock: any Clock<Duration>
    private let budget: Duration
    private let hiddenBudget: Duration
    private var pressureObservation: MainActorHandlerRegistration<MemoryPressureLevel>?

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
    public init(
        pressure: MemoryPressureEvents,
        mode: MemorySaverMode = .medium,
        slicer: any MemoryReleaseSlicer,
        turns: (any MemoryReleaseTurns)? = nil,
        clock: any Clock<Duration> = ContinuousClock(),
        sliceBudget: Duration = MemoryCoordinator.sliceBudget,
        hiddenSliceBudget: Duration = MemoryCoordinator.hiddenSliceBudget
    ) {
        let initial = pressure.currentLevel
        level = initial
        kernelLevel = initial
        policy = MemoryLimitPolicy(mode: mode)
        self.slicer = slicer
        self.turns = turns
        self.clock = clock
        budget = sliceBudget
        hiddenBudget = hiddenSliceBudget
        pressureObservation = pressure.observe { [weak self] level in self?.kernelLevelDidChange(level) }
    }

    /// The limit a consumer with `traits` has at the current level and mode.
    ///
    /// - Parameter traits: The consumer's traits.
    /// - Returns: Its limit.
    public func limit(for traits: MemoryConsumerTraits) -> MemoryLimit {
        policy.limit(for: traits, at: level)
    }

    /// Notes that the person gave input: while the app is hidden, the next slice goes back to a frame
    /// at ``sliceBudget`` until the app is hidden again. Cheap enough for every input event.
    public func inputDidArrive() {
        guard isAppHidden, !inputSinceHidden else { return }
        inputSinceHidden = true
        paceInputsDidChange()
    }

    public func addMemoryConsumer(_ entry: MemoryConsumerEntry) {
        dropReleased()
        let current = self.limit(for: entry.traits)
        let registered = Registered(entry: entry, sequence: nextSequence, limit: current)
        nextSequence &+= 1
        let index = consumers.firstIndex { registered.releasesBefore($0) } ?? consumers.endIndex
        consumers.insert(registered, at: index)
        entry.liveConsumer?.updateMemoryLimit(current)
        if registered.needsRelease { scheduleSlice() }
    }

    private func kernelLevelDidChange(_ newLevel: MemoryPressureLevel) {
        kernelLevel = newLevel
        levelInputsDidChange()
    }

    private func levelInputsDidChange() {
        let newLevel = pressureOverride ?? kernelLevel
        guard newLevel != level else { return }
        level = newLevel
        applyLimits()
    }

    /// Hands each consumer whose limit changed its new limit, and asks for a slice when one fell.
    private func applyLimits() {
        dropReleased()
        var needsRelease = false
        for registered in consumers {
            let newLimit = self.limit(for: registered.entry.traits)
            guard newLimit != registered.limit, let consumer = registered.entry.liveConsumer else { continue }
            registered.setLimit(newLimit)
            needsRelease = needsRelease || registered.needsRelease
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
        runSlice(budget: arrived == .frames ? budget : hiddenBudget)
    }

    /// One slice's release: the consumers over their limit, in order, until `sliceTime` is spent.
    private func runSlice(budget sliceTime: Duration) {
        needsSlice = false
        dropReleased()
        let isExpired = Self.deadline(on: clock, after: sliceTime)
        for registered in consumers where registered.needsRelease {
            guard !isExpired() else {
                scheduleSlice()
                return
            }
            // A consumer called before may have released this one's registration.
            guard let consumer = registered.entry.liveConsumer else { continue }
            let target = registered.limit
            switch consumer.releaseMemory(within: MemoryReleaseSlice(limit: target, isExpired: isExpired)) {
            case .done:
                registered.didRelease(to: target)
            case .more:
                scheduleSlice()
                return
            }
        }
    }

    private func dropReleased() {
        consumers.removeAll { !$0.entry.isLive }
    }

    /// A check that turns true `budget` after now on `clock`, shared by every consumer of one slice.
    private nonisolated static func deadline(on clock: some Clock<Duration>, after budget: Duration)
        -> @Sendable () -> Bool {
        let end = clock.now.advanced(by: budget)
        return { clock.now >= end }
    }
}

/// One registered consumer and what the coordinator knows of it.
@MainActor
private final class Registered {
    let entry: MemoryConsumerEntry
    let order: MemoryReleaseOrder
    let sequence: UInt64
    /// The limit it was last given.
    private(set) var limit: MemoryLimit
    /// The most it may hold now: its limit when it last finished a release, or a higher limit given
    /// since. It needs a release while its limit is below this.
    private var heldBound = MemoryLimit.default

    init(entry: MemoryConsumerEntry, sequence: UInt64, limit: MemoryLimit) {
        self.entry = entry
        order = MemoryReleaseOrder(traits: entry.traits)
        self.sequence = sequence
        self.limit = limit
    }

    var needsRelease: Bool {
        limit < heldBound
    }

    func releasesBefore(_ other: Registered) -> Bool {
        order < other.order || (order == other.order && sequence < other.sequence)
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
