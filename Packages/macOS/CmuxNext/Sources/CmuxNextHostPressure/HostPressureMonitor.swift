import Dispatch
public import Foundation

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
        self.host = host ?? HostSampler().hostName()
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
        let rate = sampler.swappedOutBytes().map { swap.feed(bytes: $0, seconds: ProcessInfo.processInfo.systemUptime) } ?? 0
        return HostBudgetVerdict(host: host, cores: cores, load1: sampler.load1(), loadLimit: formula.loadLimit(cores: cores),
                                 pressure: sampler.memoryPressure(), swapMBPerMin: rate, swapLimit: formula.swapGrowthMBPerMin)
    }
}

/// Watches the host's pressure off the main thread and tells the main actor
/// only when the level changes (`HostPressureTracker`).
///
/// Memory pressure comes from `DispatchSource.makeMemoryPressureSource`
/// (event-driven). Load and swap, and acpmux's verdict, are read on one
/// timer every `interval` (15 s), never per frame. Stop condition: `stop()`,
/// which the app calls when its last window closes or it quits; cleanup:
/// it cancels the dispatch source, the timer and any read in flight.
public actor HostPressureMonitor {
    public typealias Change = @MainActor @Sendable (HostPressureLevel, HostBudgetVerdict) -> Void

    private let source: any HostPressureSource
    private let interval: Duration
    private let queue = DispatchQueue(label: "com.cmux.host-pressure", qos: .utility)
    private var tracker: HostPressureTracker
    private var memorySource: (any DispatchSourceMemoryPressure)?
    private var timer: (any DispatchSourceTimer)?
    private var eventPressure: HostMemoryPressure?
    private var reading: Task<HostBudgetVerdict, Never>?
    private var onChange: Change?
    private var running = false
    /// Off in tests, which drive `read()` and `memoryPressureChanged(_:)` themselves.
    private let ticks: Bool

    public init(source: any HostPressureSource, interval: Duration = .seconds(15), calmSamples: Int = 2, ticks: Bool = true) {
        self.source = source
        self.interval = interval
        self.ticks = ticks
        tracker = HostPressureTracker(calmSamples: calmSamples)
    }

    public var isRunning: Bool { running }
    public var level: HostPressureLevel { tracker.level }
    /// The newest verdict (the popover's numbers).
    public var verdict: HostBudgetVerdict? { tracker.verdict }

    /// Starts the source and the timer (idempotent); the first read runs now.
    public func start(onChange: @escaping Change) {
        self.onChange = onChange
        guard !running else { return }
        running = true
        guard ticks else { return }
        (memorySource, timer) = Self.makeSources(for: self, queue: queue, interval: interval)
    }

    /// The memory pressure source and the timer, built outside the actor:
    /// their handlers run on `queue` and only hop into the monitor.
    private nonisolated static func makeSources(for monitor: HostPressureMonitor, queue: DispatchQueue, interval: Duration)
        -> (any DispatchSourceMemoryPressure, any DispatchSourceTimer) {
        let memory = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: queue)
        memory.setEventHandler { [weak monitor, weak memory] in
            guard let monitor, let event = memory?.data else { return }
            let pressure: HostMemoryPressure = event.contains(.critical) ? .critical : event.contains(.warning) ? .warn : .normal
            // task-owner: one hop per kernel event into the monitor; it ends when the event is applied
            Task { await monitor.memoryPressureChanged(pressure) }
        }
        memory.activate()
        // wakeup-allow: load and swap have no event; one 15 s read with 2 s leeway, cancelled by stop()
        let tick = DispatchSource.makeTimerSource(queue: queue)
        let seconds = Double(interval.components.seconds) + Double(interval.components.attoseconds) / 1e18
        tick.schedule(deadline: .now(), repeating: seconds, leeway: .seconds(2))
        tick.setEventHandler { [weak monitor] in
            guard let monitor else { return }
            // task-owner: one hop per tick; the read itself is `reading`, which stop() cancels
            Task { await monitor.read() }
        }
        tick.activate()
        return (memory, tick)
    }

    /// Cancels the dispatch source, the timer and a read in flight.
    public func stop() {
        running = false
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

    /// One timer tick: acpmux's verdict, else the local one.
    func read() async {
        guard running, reading == nil else { return }
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
        guard running, !task.isCancelled else { return }
        // The event source's level is newer than a sampled one until the next event.
        apply(eventPressure.map { verdict.with(pressure: $0) } ?? verdict)
    }

    func memoryPressureChanged(_ pressure: HostMemoryPressure) {
        guard running else { return }
        eventPressure = pressure
        guard let last = tracker.verdict else { return }
        apply(last.with(pressure: pressure))
    }

    private func apply(_ verdict: HostBudgetVerdict) {
        guard let level = tracker.feed(verdict), let onChange else { return }
        // task-owner: hands one level change to the main actor; ends after the call
        Task { @MainActor in onChange(level, verdict) }
    }
}
