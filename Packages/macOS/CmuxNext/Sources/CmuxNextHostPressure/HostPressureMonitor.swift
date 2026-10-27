import CmuxNextCompat
import Dispatch
public import Foundation

/// Where a verdict comes from: acpmux's `host_pressure` when the daemon
/// reports one (the one implementation of the budget), else this Mac's own
/// numbers through the same formula.
public protocol HostPressureSource: Sendable {
    /// acpmux's verdict, nil while the daemon does not report one.
    func acpmuxVerdict() async -> HostBudgetVerdict?
    /// The local verdict (`HostSampler` through the formula) at memory pressure `pressure`, the
    /// shared feed's level. With no feed (`unknown`) the source reads the level with its other
    /// numbers where the host reports one (Linux PSI).
    func localVerdict(pressure: HostMemoryPressure) async -> HostBudgetVerdict
}

/// The host's own numbers, read through the shared formula, and acpmux's
/// verdict through `acpmux` (the app runs `acpmux --json daemon status`).
public actor LocalHostPressureSource: HostPressureSource {
    private let sampler: HostSampler
    private let host: String
    /// Read from the override file on the first local read, off the caller's thread.
    private lazy var formula = HostBudgetFile.loadFormula(host: host)
    private var swap = SwapRate()
    private let acpmux: (@Sendable () async -> HostBudgetVerdict?)?
    /// Reads to skip after acpmux reported no verdict (an older daemon, or
    /// none running): one try every `acpmuxRetryReads` reads, not a process per tick.
    public static let acpmuxRetryReads = 20
    private var acpmuxSkips = 0

    /// `host` defaults to the kernel's host name (a sysctl or /proc read, not a name lookup);
    /// `acpmux` reads its verdict, and nil means there is no acpmux to ask.
    public init(host: String? = nil, acpmux: (@Sendable () async -> HostBudgetVerdict?)? = nil) {
        self.init(host: host, sampler: HostSampler(), acpmux: acpmux)
    }

    init(host: String?, sampler: HostSampler, acpmux: (@Sendable () async -> HostBudgetVerdict?)?) {
        self.sampler = sampler
        self.host = HostBudgetFile.shortName(host ?? sampler.hostName())
        self.acpmux = acpmux
    }

    public func acpmuxVerdict() async -> HostBudgetVerdict? {
        guard let acpmux else { return nil }
        guard acpmuxSkips == 0 else {
            acpmuxSkips -= 1
            return nil
        }
        let verdict = await acpmux()
        if verdict == nil { acpmuxSkips = Self.acpmuxRetryReads - 1 }
        return verdict
    }

    public func localVerdict(pressure: HostMemoryPressure) -> HostBudgetVerdict {
        let formula = formula
        let cores = sampler.cores(formula.cores)
        let rate = sampler.swappedOutBytes().flatMap { swap.feed(bytes: $0, seconds: ProcessInfo.processInfo.systemUptime) }
        let pressure = pressure == .unknown ? sampler.memoryPressure(formula: formula) ?? .unknown : pressure
        return HostBudgetVerdict(host: host, cores: cores.count, coresKind: cores.kind, load1: sampler.load1(), pressure: pressure,
                                 availableRAMFraction: sampler.availableRAMFraction(), swapMBPerMin: rate, formula: formula)
    }
}

/// Watches the host's pressure off the main thread and tells the main actor
/// only when the level changes (`HostPressureTracker`).
///
/// Memory pressure comes only from the app's one shared pressure feed
/// (`memoryPressure`, event-driven): its level when the run subscribes, then
/// each change in the order the feed sent it. A host with no feed (Linux, where
/// the level is PSI) passes nil: the source's verdict carries the level, read
/// with load and swap on the same tick, as acpmux reads it. The monitor has no kernel source
/// or sysctl read of its own: Chrome's `MemoryPressureListener`s share one
/// monitor the same way and read its level from it
/// (base/memory/memory_pressure_listener.cc,
/// base/memory/memory_pressure_monitor.h `GetCurrentPressureLevel`). Load and swap, and acpmux's
/// verdict, are read on one timer every `interval` (15 s), never per frame.
/// Stop condition: `stop()`, which the app calls when its last window closes
/// or it quits; cleanup: it ends the pressure subscription, cancels the timer
/// and any read in flight, and ends the run, so a hop or a level change
/// already queued from it is dropped.
public actor HostPressureMonitor {
    public typealias Change = @MainActor @Sendable (HostPressureLevel, HostBudgetVerdict) -> Void
    /// Subscribes a handler to the shared memory pressure feed and returns the feed's level now
    /// with the call that ends the subscription. The app passes its one
    /// `MemoryPressureEvents.hostPressureSubscription`; a test passes a feed it drives.
    public typealias MemoryPressureSubscription =
        @Sendable (@escaping @Sendable (HostMemoryPressure) -> Void) -> (current: HostMemoryPressure, end: @Sendable () -> Void)
    /// How a level change reaches the main actor: a hop by default; tests hold it to run later.
    public typealias Delivery = @Sendable (@escaping @MainActor @Sendable () -> Void) -> Void
    public static let mainActorHop: Delivery = { work in
        // task-owner: hands one level change to the main actor; ends after the call
        Task { @MainActor in work() }
    }

    private let source: any HostPressureSource
    private let memoryPressure: MemoryPressureSubscription?
    private let interval: Duration
    private let deliver: Delivery
    private let queue = DispatchQueue(label: "com.cmux.host-pressure", qos: .utility)
    private var tracker: HostPressureTracker
    private var endMemoryPressure: (@Sendable () -> Void)?
    private var timer: (any DispatchSourceTimer)?
    /// The feed's level: seeded when a run subscribes, then each change.
    private var eventPressure = HostMemoryPressure.normal
    /// The run's one reader of the feed's changes, so they apply in the order they were sent.
    private var pressureChanges: Task<Void, Never>?
    /// The feed's changes kept while the reader catches up (the kernel changes level rarely).
    static let pendingPressureChanges = 32
    private var reading: Task<HostBudgetVerdict, Never>?
    private var onChange: Change?
    private var running = false
    /// Which run is live: start() and stop() each begin a new one. A source
    /// hop or a main-actor delivery from an earlier run sees a newer number
    /// and does nothing (read from the main actor too, hence the lock).
    private nonisolated let run = Mutex(0)
    /// Off in tests, which drive `read()` themselves; the pressure subscription runs either way.
    private let ticks: Bool

    public init(source: any HostPressureSource, memoryPressure: MemoryPressureSubscription?, interval: Duration = .seconds(15),
                calmSamples: Int = 2, ticks: Bool = true, deliver: @escaping Delivery = HostPressureMonitor.mainActorHop) {
        self.source = source
        self.memoryPressure = memoryPressure
        self.interval = interval
        self.deliver = deliver
        self.ticks = ticks
        tracker = HostPressureTracker(calmSamples: calmSamples)
    }

    public var isRunning: Bool { running }
    public var level: HostPressureLevel { tracker.level }
    /// The newest verdict (the popover's numbers).
    public var verdict: HostBudgetVerdict? { tracker.verdict }

    /// Subscribes to the memory pressure feed, if any, and starts the timer (idempotent); the first read
    /// runs now. `isCurrent` is checked on the actor before anything starts: a caller whose stop
    /// overtook this start returns false, and nothing starts.
    public func start(while isCurrent: @Sendable () -> Bool = { true }, onChange: @escaping Change) {
        guard isCurrent() else { return }
        self.onChange = onChange
        guard !running else { return }
        running = true
        let generation = run.withLock { state in
            state += 1
            return state
        }
        if let memoryPressure { subscribe(to: memoryPressure, generation: generation) }
        guard ticks else { return }
        timer = Self.makeTimer(for: self, generation: generation, queue: queue, interval: interval)
    }

    /// Subscribes run `generation` to the memory pressure feed: its level now, then each change.
    private func subscribe(to memoryPressure: MemoryPressureSubscription, generation: Int) {
        // A reader behind by `pendingPressureChanges` drops the oldest: the newest level always applies.
        let (changes, continuation) = AsyncStream<HostMemoryPressure>.makeStream(bufferingPolicy: .bufferingNewest(Self.pendingPressureChanges))
        let subscription = memoryPressure { pressure in continuation.yield(pressure) }
        eventPressure = subscription.current
        endMemoryPressure = {
            subscription.end()
            continuation.finish()
        }
        // task-owner: the run's one reader of the feed; it ends when stop() finishes the stream and cancels it
        pressureChanges = Task { [weak self] in
            for await pressure in changes {
                await self?.memoryPressureChanged(pressure, generation: generation)
            }
        }
    }

    /// The live run's number (tests drive the hops with it).
    var generation: Int { run.withLock { $0 } }

    /// The load and swap timer, built outside the actor: its handler runs on `queue` and only
    /// hops into the monitor.
    private nonisolated static func makeTimer(for monitor: HostPressureMonitor, generation: Int, queue: DispatchQueue,
                                              interval: Duration) -> any DispatchSourceTimer {
        // wakeup-allow: load and swap have no event; one 15 s read with 2 s leeway, cancelled by stop()
        let tick = DispatchSource.makeTimerSource(queue: queue)
        let seconds = Double(interval.components.seconds) + Double(interval.components.attoseconds) / 1e18
        tick.schedule(deadline: .now(), repeating: seconds, leeway: .seconds(2))
        tick.setEventHandler { [weak monitor] in
            guard let monitor else { return }
            // task-owner: one hop per tick; the read itself is `reading`, which stop() cancels
            Task { await monitor.read(generation: generation) }
        }
        tick.activate()
        return tick
    }

    /// Ends the memory pressure subscription; cancels the timer and a read in flight.
    public func stop() {
        running = false
        run.withLock { $0 += 1 }
        endMemoryPressure?()
        endMemoryPressure = nil
        pressureChanges?.cancel()
        pressureChanges = nil
        timer?.cancel()
        timer = nil
        reading?.cancel()
        reading = nil
        onChange = nil
        eventPressure = .normal
        tracker = HostPressureTracker(calmSamples: tracker.calmSamples)
    }

    /// Whether a hop from run `generation` (nil: the live one) may apply.
    private func isLive(_ generation: Int?) -> Bool {
        running && (generation.map { $0 == self.generation } ?? true)
    }

    /// One timer tick: acpmux's verdict, else the local one.
    func read(generation: Int? = nil) async {
        guard isLive(generation), reading == nil else { return }
        let generation = self.generation
        // With no feed the source reads the level itself (`unknown` asks it to).
        let (source, pressure) = (source, memoryPressure == nil ? HostMemoryPressure.unknown : eventPressure)
        // task-owner: this read; stop() cancels it, and a cancelled read applies nothing
        let task = Task { () -> HostBudgetVerdict in
            if let shared = await source.acpmuxVerdict() { return shared }
            return await source.localVerdict(pressure: pressure)
        }
        reading = task
        let verdict = await task.value
        // A stop() and start() during the read may have begun a newer one.
        if reading == task { reading = nil }
        guard isLive(generation), !task.isCancelled else { return }
        // The feed's level is the one memory level, over acpmux's too (and it may have changed during the read).
        apply(memoryPressure == nil ? verdict : verdict.with(pressure: eventPressure))
    }

    func memoryPressureChanged(_ pressure: HostMemoryPressure, generation: Int? = nil) {
        guard isLive(generation) else { return }
        eventPressure = pressure
        guard let last = tracker.verdict else { return }
        apply(last.with(pressure: pressure))
    }

    private func apply(_ verdict: HostBudgetVerdict) {
        guard let level = tracker.feed(verdict), let onChange else { return }
        let generation = self.generation
        // Dropped when stop() ended this run while it waited for the main actor.
        deliver { [self] in
            guard run.withLock({ $0 }) == generation else { return }
            onChange(level, verdict)
        }
    }
}
