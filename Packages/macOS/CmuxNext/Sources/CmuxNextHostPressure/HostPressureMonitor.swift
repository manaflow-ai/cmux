import Dispatch
public import Foundation
import os

/// Where a verdict comes from: acpmux's `host_pressure` when the daemon
/// reports one (the one implementation of the budget), else this Mac's own
/// numbers through the same formula.
public protocol HostPressureSource: Sendable {
    /// acpmux's verdict, nil while the daemon does not report one.
    func acpmuxVerdict() async -> HostBudgetVerdict?
    /// The local verdict (`HostSampler` through the formula).
    func localVerdict() async -> HostBudgetVerdict
}

/// The host's own numbers, read through the shared formula, and acpmux's
/// verdict through `acpmux` (the app runs `acpmux --json daemon status`).
public actor LocalHostPressureSource: HostPressureSource {
    private let sampler = HostSampler()
    private let host: String
    /// Read from the override file on the first local read, off the caller's thread.
    private lazy var formula = HostBudgetFile.loadFormula(host: host)
    private var swap = SwapRate()
    private let acpmux: (@Sendable () async -> HostBudgetVerdict?)?
    /// Reads to skip after acpmux reported no verdict (an older daemon, or
    /// none running): one try every `acpmuxRetryReads` reads, not a process per tick.
    public static let acpmuxRetryReads = 20
    private var acpmuxSkips = 0

    /// `host` defaults to kern.hostname (a sysctl, not a name lookup); `acpmux`
    /// reads its verdict, and nil means there is no acpmux to ask.
    public init(host: String? = nil, acpmux: (@Sendable () async -> HostBudgetVerdict?)? = nil) {
        self.host = HostBudgetFile.shortName(host ?? HostSampler().hostName())
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

    public func localVerdict() -> HostBudgetVerdict {
        let formula = formula
        let cores = sampler.cores(formula.cores)
        let rate = sampler.swappedOutBytes().flatMap { swap.feed(bytes: $0, seconds: ProcessInfo.processInfo.systemUptime) }
        return HostBudgetVerdict(host: host, cores: cores.count, coresKind: cores.kind, load1: sampler.load1(), pressure: sampler.memoryPressure(),
                                 availableRAMFraction: sampler.availableRAMFraction(), swapMBPerMin: rate, formula: formula)
    }
}

/// Watches the host's pressure off the main thread and tells the main actor
/// only when the level changes (`HostPressureTracker`).
///
/// Memory pressure comes from `DispatchSource.makeMemoryPressureSource`
/// (event-driven). Load and swap, and acpmux's verdict, are read on one
/// timer every `interval` (15 s), never per frame. Stop condition: `stop()`,
/// which the app calls when its last window closes or it quits; cleanup:
/// it cancels the dispatch source, the timer and any read in flight, and ends
/// the run, so a hop or a level change already queued from it is dropped.
public actor HostPressureMonitor {
    public typealias Change = @MainActor @Sendable (HostPressureLevel, HostBudgetVerdict) -> Void
    /// How a level change reaches the main actor: a hop by default; tests hold it to run later.
    public typealias Delivery = @Sendable (@escaping @MainActor @Sendable () -> Void) -> Void
    public static let mainActorHop: Delivery = { work in
        // task-owner: hands one level change to the main actor; ends after the call
        Task { @MainActor in work() }
    }

    private let source: any HostPressureSource
    private let interval: Duration
    private let deliver: Delivery
    private let queue = DispatchQueue(label: "com.cmux.host-pressure", qos: .utility)
    private var tracker: HostPressureTracker
    private var memorySource: (any DispatchSourceMemoryPressure)?
    private var timer: (any DispatchSourceTimer)?
    private var eventPressure: HostMemoryPressure?
    private var reading: Task<HostBudgetVerdict, Never>?
    private var onChange: Change?
    private var running = false
    /// Which run is live: start() and stop() each begin a new one. A source
    /// hop or a main-actor delivery from an earlier run sees a newer number
    /// and does nothing (read from the main actor too, hence the lock).
    private let run = OSAllocatedUnfairLock(initialState: 0)
    /// Off in tests, which drive `read()` and `memoryPressureChanged(_:)` themselves.
    private let ticks: Bool

    public init(source: any HostPressureSource, interval: Duration = .seconds(15), calmSamples: Int = 2, ticks: Bool = true,
                deliver: @escaping Delivery = HostPressureMonitor.mainActorHop) {
        self.source = source
        self.interval = interval
        self.deliver = deliver
        self.ticks = ticks
        tracker = HostPressureTracker(calmSamples: calmSamples)
    }

    public var isRunning: Bool { running }
    public var level: HostPressureLevel { tracker.level }
    /// The newest verdict (the popover's numbers).
    public var verdict: HostBudgetVerdict? { tracker.verdict }

    /// Starts the source and the timer (idempotent); the first read runs now. `isCurrent` is
    /// checked on the actor before anything starts: a caller whose stop overtook this start
    /// returns false, and nothing starts.
    public func start(while isCurrent: @Sendable () -> Bool = { true }, onChange: @escaping Change) {
        guard isCurrent() else { return }
        self.onChange = onChange
        guard !running else { return }
        running = true
        let generation = run.withLock { state in
            state += 1
            return state
        }
        guard ticks else { return }
        (memorySource, timer) = Self.makeSources(for: self, generation: generation, queue: queue, interval: interval)
    }

    /// The live run's number (tests drive the hops with it).
    var generation: Int { run.withLock { $0 } }

    /// The memory pressure source and the timer, built outside the actor:
    /// their handlers run on `queue` and only hop into the monitor.
    private nonisolated static func makeSources(for monitor: HostPressureMonitor, generation: Int, queue: DispatchQueue,
                                                interval: Duration)
        -> (any DispatchSourceMemoryPressure, any DispatchSourceTimer) {
        let memory = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: queue)
        memory.setEventHandler { [weak monitor, weak memory] in
            guard let monitor, let event = memory?.data else { return }
            let pressure: HostMemoryPressure = event.contains(.critical) ? .critical : event.contains(.warning) ? .warn : .normal
            // task-owner: one hop per kernel event into the monitor; it ends when the event is applied
            Task { await monitor.memoryPressureChanged(pressure, generation: generation) }
        }
        memory.activate()
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
        return (memory, tick)
    }

    /// Cancels the dispatch source, the timer and a read in flight.
    public func stop() {
        running = false
        run.withLock { $0 += 1 }
        memorySource?.cancel()
        memorySource = nil
        timer?.cancel()
        timer = nil
        reading?.cancel()
        reading = nil
        onChange = nil
        eventPressure = nil
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
        let source = source
        // task-owner: this read; stop() cancels it, and a cancelled read applies nothing
        let task = Task { () -> HostBudgetVerdict in
            if let shared = await source.acpmuxVerdict() { return shared }
            return await source.localVerdict()
        }
        reading = task
        let verdict = await task.value
        // A stop() and start() during the read may have begun a newer one.
        if reading == task { reading = nil }
        guard isLive(generation), !task.isCancelled else { return }
        // The event source's level is newer than a sampled one until the next event.
        apply(eventPressure.map { verdict.with(pressure: $0) } ?? verdict)
    }

    func memoryPressureChanged(_ pressure: HostMemoryPressure, generation: Int? = nil) {
        guard isLive(generation) else { return }
        eventPressure = pressure
        guard let last = tracker.verdict else { return }
        apply(last.with(pressure: pressure))
    }

    private func apply(_ verdict: HostBudgetVerdict) {
        guard let level = tracker.feed(verdict), let onChange else { return }
        let run = run
        let generation = self.generation
        // Dropped when stop() ended this run while it waited for the main actor.
        deliver {
            guard run.withLock({ $0 }) == generation else { return }
            onChange(level, verdict)
        }
    }
}
